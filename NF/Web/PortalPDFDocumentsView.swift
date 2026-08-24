//
//  PortalPDFDocumentsView.swift
//  NF
//
//  Created by Codex on 8/8/26.
//

import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/** 로컬에 저장된 PDF를 웹 포털과 동일한 다크 UI로 관리하는 네이티브 문서 화면입니다. */
struct PortalPDFDocumentsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.portalAppTheme) private var portalTheme
    private let repository = PortalPDFLocalStorageRepository()

    @State private var selectedSection: PortalPDFDocumentSection = .all
    @State private var searchQuery = ""
    @State private var documents: [PortalLocalPDFDocument] = []
    @State private var folders: [PortalLocalPDFFolder] = []
    @State private var selectedFolderID: String?
    @State private var targetedFolderID: String?
    @State private var selectedDocument: PortalLocalPDFDocument?
    @State private var deletionRequest: PortalPDFDocumentDeletionRequest?
    @State private var renamingDocument: PortalLocalPDFDocument?
    @State private var renameText = ""
    @State private var isDocumentAddMenuPresented = false
    @State private var documentInputPrompt: PortalPDFDocumentInputPrompt?
    @State private var documentInputText = ""
    @State private var isFileImporterPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isCloudCenterPresented = false
    @State private var isAddingDocument = false
    @State private var addingDocumentMessage = "문서를 추가하고 있습니다."
    @State private var errorMessage: String?

    private var documentLibraryBackgroundColor: Color {
        portalTheme.documentLibraryBackgroundColor
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    pageHeader
                    sectionTabs
                    if selectedSection == .search {
                        searchField
                    }
                    documentContent
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(documentLibraryBackgroundColor.ignoresSafeArea())
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        dismissToolbarButton
                    }
                    .sharedBackgroundVisibility(.hidden)

                    ToolbarItem(placement: .topBarTrailing) {
                        documentToolbarActions
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        dismissToolbarButton
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        documentToolbarActions
                    }
                }
            }
            .toolbarBackground(documentLibraryBackgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(portalTheme.colorScheme, for: .navigationBar)
            .tint(portalTheme.accentColor)
            .task {
                reloadDocuments()
            }
            .onReceive(NotificationCenter.default.publisher(for: PortalPDFLocalStorageRepository.didChangeNotification)) { _ in
                reloadDocuments()
            }
            .fullScreenCover(item: $selectedDocument, onDismiss: reloadDocuments) { document in
                PortalPDFPreviewView(item: PortalAttachmentPreviewItem(localDocument: document))
            }
            .fullScreenCover(isPresented: $isCloudCenterPresented, onDismiss: reloadDocuments) {
                PortalPDFCloudCenterView()
            }
            .confirmationDialog(
                "문서 추가",
                isPresented: $isDocumentAddMenuPresented,
                titleVisibility: .visible
            ) {
                documentAddMenuButtons
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                handleImportedPDF(result)
            }
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task { await addPhotoAsPDF(item) }
            }
            .alert(item: $deletionRequest) { request in
                deletionAlert(for: request)
            }
            .alert("이름 변경", isPresented: Binding(
                get: { renamingDocument != nil },
                set: { if !$0 { renamingDocument = nil } }
            )) {
                TextField("파일명", text: $renameText)
                Button("취소", role: .cancel) {
                    renamingDocument = nil
                }
                Button("변경") {
                    applyRename()
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("목록에 표시할 PDF 파일명을 입력해 주세요.")
            }
            .alert(documentInputPrompt?.title ?? "문서 추가", isPresented: Binding(
                get: { documentInputPrompt != nil },
                set: { if !$0 { documentInputPrompt = nil } }
            )) {
                TextField(documentInputPrompt?.placeholder ?? "이름", text: $documentInputText)
                    .textInputAutocapitalization(.never)
                Button("취소", role: .cancel) {
                    documentInputPrompt = nil
                }
                Button("확인") {
                    submitDocumentInputPrompt()
                }
                .disabled(documentInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text(documentInputPrompt?.message ?? "정보를 입력해 주세요.")
            }
            .alert("문서 처리 실패", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "PDF 문서를 처리하지 못했습니다.")
            }
            .overlay {
                if isAddingDocument {
                    addingDocumentOverlay
                }
            }
        }
        .background(documentLibraryBackgroundColor.ignoresSafeArea())
        .preferredColorScheme(portalTheme.colorScheme)
    }

    private var dismissToolbarButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("웹 포털로 돌아가기")
        .accessibilityHint("네이티브 문서 화면을 닫고 기존 웹페이지로 돌아갑니다.")
    }

    private var addDocumentToolbarButton: some View {
        Button {
            isDocumentAddMenuPresented = true
        } label: {
            Image(systemName: "plus")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("문서 추가")
    }

    private var documentToolbarActions: some View {
        HStack(spacing: 2) {
            Button {
                isCloudCenterPresented = true
            } label: {
                Image(systemName: "icloud")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("클라우드 문서")
            .accessibilityHint("iCloud와 Google Drive 동기화 화면을 엽니다.")

            addDocumentToolbarButton
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("문서")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(portalTheme.foregroundColor)
            Text("기기에 저장된 PDF를 검색하고 즐겨찾기와 휴지통을 관리합니다.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(portalTheme.mutedColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(portalTheme.borderColor.opacity(0.7))
                .frame(height: 1)
        }
    }

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(PortalPDFDocumentSection.allCases) { section in
                    Button {
                        selectedSection = section
                        if section != .all {
                            selectedFolderID = nil
                        }
                    } label: {
                        VStack(spacing: 9) {
                            Label(section.title, systemImage: section.systemImageName)
                                .font(.system(size: 14, weight: .semibold))
                            Rectangle()
                                .fill(selectedSection == section ? portalTheme.foregroundColor : .clear)
                                .frame(height: 2)
                        }
                        .foregroundStyle(selectedSection == section ? portalTheme.foregroundColor : portalTheme.mutedColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.bottom, 2)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(portalTheme.mutedColor)
            TextField("PDF 파일명 검색", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(portalTheme.mutedColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("검색어 지우기")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(portalTheme.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(portalTheme.borderColor, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var documentAddMenuButtons: some View {
        Button {
            presentDocumentInput(.newDocument)
        } label: {
            Label("새 문서", systemImage: "doc.badge.plus")
        }

        Button {
            isFileImporterPresented = true
        } label: {
            Label("파일·iCloud·Drive에서 가져오기", systemImage: "folder")
        }

        Button {
            presentDocumentInput(.link)
        } label: {
            Label("링크 추가하기", systemImage: "link")
        }

        Button {
            presentDocumentInput(.newFolder)
        } label: {
            Label("새 폴더", systemImage: "folder.badge.plus")
        }

        Button {
            isPhotoPickerPresented = true
        } label: {
            Label("사진 앨범", systemImage: "photo.on.rectangle")
        }

        Button("취소", role: .cancel) {}
    }

    private var addingDocumentOverlay: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(addingDocumentMessage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(portalTheme.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(addingDocumentMessage)
    }

    @ViewBuilder
    private var documentContent: some View {
        let visibleDocuments = filteredDocuments
        if let selectedFolder {
            selectedFolderHeader(selectedFolder)
        }
        if selectedSection == .all && selectedFolderID == nil {
            ForEach(folders) { folder in
                folderRow(folder)
            }
        }
        if visibleDocuments.isEmpty && (selectedSection != .all || selectedFolderID != nil || folders.isEmpty) {
            emptyState
        } else {
            ForEach(visibleDocuments) { document in
                documentRow(document)
            }
        }
    }

    private func selectedFolderHeader(_ folder: PortalLocalPDFFolder) -> some View {
        Button {
            selectedFolderID = nil
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "chevron.left")
                Image(systemName: "folder.fill")
                    .foregroundStyle(portalTheme.accentColor)
                Text(folder.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(portalTheme.foregroundColor)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(portalTheme.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("상위 문서 목록으로 이동")
    }

    private func folderRow(_ folder: PortalLocalPDFFolder) -> some View {
        let fileCount = documents.filter { !$0.isDeleted && $0.folderID == folder.id }.count
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(portalTheme.accentColor.opacity(0.14))
                Image(systemName: "folder.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(portalTheme.accentColor)
            }
            .frame(width: 46, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                Text(folder.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(portalTheme.foregroundColor)
                    .lineLimit(2)
                Text("PDF \(fileCount)개")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(portalTheme.mutedColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .foregroundStyle(portalTheme.mutedColor)
        }
        .padding(15)
        .background(
            targetedFolderID == folder.id
                ? portalTheme.accentColor.opacity(0.16)
                : portalTheme.documentLibraryCardBackgroundColor
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    targetedFolderID == folder.id ? portalTheme.accentColor : portalTheme.borderColor.opacity(0.9),
                    lineWidth: targetedFolderID == folder.id ? 2 : 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedFolderID = folder.id
        }
        .dropDestination(for: String.self) { documentIDs, _ in
            moveDocuments(documentIDs, to: folder)
        } isTargeted: { isTargeted in
            targetedFolderID = isTargeted ? folder.id : nil
        }
        .accessibilityHint("폴더를 열거나 문서를 길게 눌러 이 폴더로 이동할 수 있습니다.")
    }

    private func documentRow(_ document: PortalLocalPDFDocument) -> some View {
        HStack(alignment: .center, spacing: 14) {
            PortalPDFDocumentThumbnailView(document: document)

            VStack(alignment: .leading, spacing: 6) {
                Text(document.fileName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(portalTheme.foregroundColor)
                    .lineLimit(2)
                Text(metadataText(for: document))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(portalTheme.mutedColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    beginRenaming(document)
                } label: {
                    Label("이름 변경", systemImage: "pencil")
                }

                if document.isDeleted {
                    Button {
                        restore(document)
                    } label: {
                        Label("복원", systemImage: "arrow.counterclockwise")
                    }

                    Divider()

                    Button(role: .destructive) {
                        deletionRequest = PortalPDFDocumentDeletionRequest(document: document, kind: .permanent)
                    } label: {
                        Label("완전 삭제", systemImage: "trash.fill")
                    }
                } else {
                    Button {
                        toggleFavorite(document)
                    } label: {
                        Label(
                            document.isFavorite ? "즐겨찾기에서 제거" : "즐겨찾기",
                            systemImage: document.isFavorite ? "star.slash" : "star"
                        )
                    }

                    Divider()

                    Button(role: .destructive) {
                        deletionRequest = PortalPDFDocumentDeletionRequest(document: document, kind: .trash)
                    } label: {
                        Label("삭제", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(portalTheme.mutedColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("\(document.fileName) 더보기")
        }
        .padding(15)
        .background(portalTheme.documentLibraryCardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(portalTheme.borderColor.opacity(0.9), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !document.isDeleted else { return }
            selectedDocument = document
        }
        .draggable(document.id) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext.fill")
                    .foregroundStyle(portalTheme.accentColor)
                Text(document.fileName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(portalTheme.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityHint(document.isDeleted ? "복원하거나 완전히 삭제할 수 있습니다." : "두 번 탭하면 PDF 편집을 시작합니다.")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedSection == .trash ? "trash" : "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(portalTheme.mutedColor)
            Text(emptyStateText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(portalTheme.mutedColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(portalTheme.surfaceColor.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(portalTheme.borderColor, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }
    }

    private var filteredDocuments: [PortalLocalPDFDocument] {
        switch selectedSection {
        case .all:
            return documents.filter { !$0.isDeleted && $0.folderID == selectedFolderID }
        case .search:
            let activeDocuments = documents.filter { !$0.isDeleted }
            guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return activeDocuments
            }
            return activeDocuments.filter {
                $0.fileName.localizedCaseInsensitiveContains(searchQuery)
            }
        case .favorites:
            return documents.filter { !$0.isDeleted && $0.isFavorite }
        case .trash:
            return documents
                .filter(\.isDeleted)
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        }
    }

    private var selectedFolder: PortalLocalPDFFolder? {
        guard let selectedFolderID else { return nil }
        return folders.first { $0.id == selectedFolderID }
    }

    private var emptyStateText: String {
        if selectedSection == .all, selectedFolderID != nil {
            return "이 폴더에 저장된 PDF 문서가 없습니다."
        }
        switch selectedSection {
        case .all: return "로컬에 저장된 PDF 문서가 없습니다."
        case .search: return "파일명과 일치하는 PDF 문서가 없습니다."
        case .favorites: return "즐겨찾기한 PDF 문서가 없습니다."
        case .trash: return "휴지통이 비어 있습니다."
        }
    }

    private func metadataText(for document: PortalLocalPDFDocument) -> String {
        let size = ByteCountFormatter.string(fromByteCount: document.fileSize, countStyle: .file)
        if let deletedAt = document.deletedAt {
            let purgeDate = deletedAt.addingTimeInterval(PortalPDFLocalStorageRepository.trashRetentionInterval)
            return "삭제 \(deletedAt.formatted(date: .abbreviated, time: .shortened)) · 보관 기한 \(purgeDate.formatted(date: .abbreviated, time: .omitted)) · \(size)"
        }
        return "수정 \(document.modifiedAt.formatted(date: .abbreviated, time: .shortened)) · \(size)"
    }

    private func reloadDocuments() {
        documents = repository.documents()
        folders = repository.folders()
    }

    private func toggleFavorite(_ document: PortalLocalPDFDocument) {
        do {
            try repository.toggleFavorite(documentID: document.id)
            reloadDocuments()
        } catch {
            errorMessage = "즐겨찾기 상태를 변경하지 못했습니다."
        }
    }

    private func beginRenaming(_ document: PortalLocalPDFDocument) {
        renameText = document.fileName
        renamingDocument = document
    }

    private func applyRename() {
        guard let document = renamingDocument else { return }
        do {
            try repository.rename(documentID: document.id, fileName: renameText)
            renamingDocument = nil
            reloadDocuments()
        } catch {
            renamingDocument = nil
            errorMessage = "PDF 파일명을 변경하지 못했습니다."
        }
    }

    private func presentDocumentInput(_ prompt: PortalPDFDocumentInputPrompt) {
        documentInputText = ""
        documentInputPrompt = prompt
    }

    private func submitDocumentInputPrompt() {
        guard let prompt = documentInputPrompt else { return }
        let input = documentInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        documentInputPrompt = nil
        switch prompt {
        case .newDocument:
            createBlankDocument(named: input)
        case .link:
            Task { await addPDFLink(input) }
        case .newFolder:
            createFolder(named: input)
        }
    }

    private func createBlankDocument(named name: String) {
        do {
            let pageBounds = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
            let data = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
                context.beginPage()
            }
            let document = try repository.createDocument(
                data: data,
                fileName: name,
                folderID: selectedFolderID
            )
            finishAddingDocument(document)
        } catch {
            errorMessage = "새 PDF 문서를 생성하지 못했습니다."
        }
    }

    private func createFolder(named name: String) {
        do {
            _ = try repository.createFolder(name: name)
            selectedSection = .all
            selectedFolderID = nil
            reloadDocuments()
        } catch {
            errorMessage = "새 폴더를 생성하지 못했습니다."
        }
    }

    private func handleImportedPDF(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await addImportedPDF(url) }
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled {
                errorMessage = "PDF 파일을 불러오지 못했습니다."
            }
        }
    }

    @MainActor
    private func addImportedPDF(_ url: URL) async {
        beginAddingDocument(message: "PDF 파일을 불러오고 있습니다.")
        defer { isAddingDocument = false }
        do {
            let folderID = selectedFolderID
            let data = try await Task.detached(priority: .userInitiated) {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                return try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            let document = try repository.createDocument(
                data: data,
                fileName: url.lastPathComponent,
                folderID: folderID
            )
            finishAddingDocument(document)
        } catch {
            errorMessage = "선택한 파일이 유효한 PDF가 아니거나 불러올 수 없습니다."
        }
    }

    @MainActor
    private func addPDFLink(_ input: String) async {
        beginAddingDocument(message: "링크에서 PDF를 가져오고 있습니다.")
        defer { isAddingDocument = false }
        do {
            let normalizedInput = input.contains("://") ? input : "https://\(input)"
            guard let url = URL(string: normalizedInput),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                throw PortalPDFDocumentAdditionError.invalidLink
            }
            var request = URLRequest(url: url)
            request.setValue("application/pdf, application/octet-stream;q=0.8", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw PortalPDFDocumentAdditionError.downloadFailed
            }
            guard let pdfDocument = PDFDocument(data: data), pdfDocument.pageCount > 0 else {
                throw PortalPDFDocumentAdditionError.notPDF
            }
            let suggestedName = response.suggestedFilename
                ?? (url.lastPathComponent.isEmpty ? "링크 문서.pdf" : url.lastPathComponent)
            let document = try repository.createDocument(
                data: data,
                fileName: suggestedName,
                sourceURL: url,
                folderID: selectedFolderID
            )
            finishAddingDocument(document)
        } catch PortalPDFDocumentAdditionError.notPDF {
            errorMessage = "입력한 링크의 파일은 PDF 문서가 아닙니다."
        } catch PortalPDFDocumentAdditionError.invalidLink {
            errorMessage = "올바른 PDF 링크를 입력해 주세요."
        } catch {
            errorMessage = "링크에서 PDF 파일을 가져오지 못했습니다."
        }
    }

    @MainActor
    private func addPhotoAsPDF(_ item: PhotosPickerItem) async {
        beginAddingDocument(message: "사진을 PDF 문서로 변환하고 있습니다.")
        defer {
            selectedPhotoItem = nil
            isAddingDocument = false
        }
        do {
            guard let imageData = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: imageData) else {
                throw PortalPDFDocumentAdditionError.photoConversionFailed
            }
            let data = pdfData(from: image)
            let name = "사진 \(Date().formatted(date: .numeric, time: .shortened)).pdf"
            let document = try repository.createDocument(
                data: data,
                fileName: name,
                folderID: selectedFolderID
            )
            finishAddingDocument(document)
        } catch {
            errorMessage = "선택한 사진을 PDF 문서로 변환하지 못했습니다."
        }
    }

    private func pdfData(from image: UIImage) -> Data {
        let isLandscape = image.size.width > image.size.height
        let pageSize = isLandscape
            ? CGSize(width: 841.8, height: 595.2)
            : CGSize(width: 595.2, height: 841.8)
        let pageBounds = CGRect(origin: .zero, size: pageSize)
        let contentBounds = pageBounds.insetBy(dx: 28, dy: 28)
        let scale = min(contentBounds.width / image.size.width, contentBounds.height / image.size.height)
        let imageSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let imageBounds = CGRect(
            x: contentBounds.midX - imageSize.width / 2,
            y: contentBounds.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        return UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            image.draw(in: imageBounds)
        }
    }

    private func beginAddingDocument(message: String) {
        addingDocumentMessage = message
        isAddingDocument = true
    }

    private func finishAddingDocument(_ document: PortalLocalPDFDocument) {
        reloadDocuments()
        selectedDocument = document
    }

    private func moveDocuments(_ documentIDs: [String], to folder: PortalLocalPDFFolder) -> Bool {
        var didMoveDocument = false
        do {
            for documentID in documentIDs where !documentID.isEmpty {
                guard documents.contains(where: { $0.id == documentID && !$0.isDeleted }) else { continue }
                try repository.moveDocument(documentID: documentID, toFolderID: folder.id)
                didMoveDocument = true
            }
            if didMoveDocument { reloadDocuments() }
        } catch {
            errorMessage = "PDF 문서를 폴더로 이동하지 못했습니다."
        }
        targetedFolderID = nil
        return didMoveDocument
    }

    private func restore(_ document: PortalLocalPDFDocument) {
        do {
            try repository.restore(documentID: document.id)
            reloadDocuments()
        } catch {
            errorMessage = "PDF 문서를 복원하지 못했습니다."
        }
    }

    private func deletionAlert(for request: PortalPDFDocumentDeletionRequest) -> Alert {
        let permanent = request.kind == .permanent
        return Alert(
            title: Text(permanent ? "PDF 문서를 완전히 삭제할까요?" : "PDF 문서를 휴지통으로 이동할까요?"),
            message: Text(permanent
                ? "“\(request.document.fileName)” 파일은 즉시 영구 삭제되며 복원할 수 없습니다."
                : "“\(request.document.fileName)” 파일은 휴지통에서 7일 동안 복원할 수 있습니다."),
            primaryButton: .destructive(Text(permanent ? "완전 삭제" : "삭제")) {
                performDeletion(request)
            },
            secondaryButton: .cancel(Text("취소"))
        )
    }

    private func performDeletion(_ request: PortalPDFDocumentDeletionRequest) {
        do {
            switch request.kind {
            case .trash:
                try repository.moveToTrash(documentID: request.document.id)
            case .permanent:
                try repository.permanentlyDelete(documentID: request.document.id)
            }
            reloadDocuments()
        } catch {
            errorMessage = request.kind == .permanent
                ? "PDF 문서를 완전히 삭제하지 못했습니다."
                : "PDF 문서를 휴지통으로 이동하지 못했습니다."
        }
    }
}

/// PDF 타이틀 메뉴에서 현재 문서를 다른 폴더로 이동할 때 전달하는 가벼운 시트 정보입니다.
struct PortalPDFDocumentMovePresentation: Identifiable {
    let id = UUID()
    let documentID: String
    let documentTitle: String
    let currentFolderID: String?
}

/// 전체 문서 모드의 폴더 중 현재 위치를 제외한 이동 가능한 폴더만 표시합니다.
struct PortalPDFDocumentMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.portalAppTheme) private var portalTheme
    private let repository = PortalPDFLocalStorageRepository()

    let presentation: PortalPDFDocumentMovePresentation
    @State private var folders: [PortalLocalPDFFolder] = []
    @State private var selectedFolderID: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if movableFolders.isEmpty {
                    ContentUnavailableView(
                        "이동 가능한 폴더가 없습니다",
                        systemImage: "folder.badge.questionmark",
                        description: Text("전체 문서 화면에서 새 폴더를 만든 후 다시 시도해 주세요.")
                    )
                } else {
                    List(movableFolders) { folder in
                        Button {
                            selectedFolderID = folder.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(portalTheme.accentColor)
                                Text(folder.name)
                                    .foregroundStyle(portalTheme.foregroundColor)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Image(systemName: selectedFolderID == folder.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedFolderID == folder.id ? portalTheme.accentColor : portalTheme.mutedColor)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(folder.name) 폴더")
                        .accessibilityAddTraits(selectedFolderID == folder.id ? .isSelected : [])
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("파일 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("이동") {
                        moveDocument()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedFolderID == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("‘\(presentation.documentTitle)’ 문서 편집은 이동 후에도 그대로 유지됩니다.")
                    .font(.caption)
                    .foregroundStyle(portalTheme.mutedColor)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
            }
            .task {
                folders = repository.folders()
            }
            .alert("파일 이동 실패", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "문서를 선택한 폴더로 이동하지 못했습니다.")
            }
        }
        .preferredColorScheme(portalTheme.colorScheme)
    }

    private var movableFolders: [PortalLocalPDFFolder] {
        folders.filter { $0.id != presentation.currentFolderID }
    }

    private func moveDocument() {
        guard let selectedFolderID else { return }
        do {
            try repository.moveDocument(
                documentID: presentation.documentID,
                toFolderID: selectedFolderID
            )
            dismiss()
        } catch {
            errorMessage = "문서를 선택한 폴더로 이동하지 못했습니다."
        }
    }
}

/// 문서 목록이 다시 표시될 때 동일 PDF의 첫 페이지를 반복 렌더링하지 않도록 썸네일을 보관합니다.
@MainActor
private enum PortalPDFDocumentThumbnailCache {
    static let images = NSCache<NSString, UIImage>()
}

/// 로컬 PDF 첫 페이지를 파일 정보 왼쪽의 문서 썸네일로 표시합니다.
private struct PortalPDFDocumentThumbnailView: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let document: PortalLocalPDFDocument

    @State private var thumbnail: UIImage?
    @State private var didFailToLoad = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else if didFailToLoad {
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(portalTheme.accentColor)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(portalTheme.mutedColor)
            }
        }
        .frame(width: 46, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(portalTheme.borderColor.opacity(0.9), lineWidth: 1)
        }
        .accessibilityHidden(true)
        .task(id: cacheKey) {
            loadThumbnail()
        }
    }

    private var cacheKey: String {
        "\(document.id)-\(document.modifiedAt.timeIntervalSince1970)"
    }

    @MainActor
    private func loadThumbnail() {
        let key = cacheKey as NSString
        if let cachedThumbnail = PortalPDFDocumentThumbnailCache.images.object(forKey: key) {
            thumbnail = cachedThumbnail
            didFailToLoad = false
            return
        }

        guard !Task.isCancelled,
              let pdfDocument = PDFDocument(url: document.localFileURL),
              let firstPage = pdfDocument.page(at: 0) else {
            thumbnail = nil
            didFailToLoad = true
            return
        }

        let generatedThumbnail = firstPage.thumbnail(
            of: CGSize(width: 92, height: 104),
            for: .cropBox
        )
        guard !Task.isCancelled else { return }
        PortalPDFDocumentThumbnailCache.images.setObject(generatedThumbnail, forKey: key)
        thumbnail = generatedThumbnail
        didFailToLoad = false
    }
}

private enum PortalPDFDocumentSection: String, CaseIterable, Identifiable {
    case all
    case search
    case favorites
    case trash

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "전체"
        case .search: return "검색"
        case .favorites: return "즐겨찾기"
        case .trash: return "휴지통"
        }
    }
    var systemImageName: String {
        switch self {
        case .all: return "doc.on.doc"
        case .search: return "magnifyingglass"
        case .favorites: return "star"
        case .trash: return "trash"
        }
    }
}

private enum PortalPDFDocumentInputPrompt: String, Identifiable {
    case newDocument
    case link
    case newFolder

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newDocument: return "새 문서"
        case .link: return "링크 추가하기"
        case .newFolder: return "새 폴더"
        }
    }
    var placeholder: String {
        switch self {
        case .newDocument: return "PDF 문서 이름"
        case .link: return "https://example.com/document.pdf"
        case .newFolder: return "폴더 이름"
        }
    }
    var message: String {
        switch self {
        case .newDocument: return "새 PDF 문서의 이름을 입력해 주세요."
        case .link: return "가져올 PDF 파일의 링크를 입력해 주세요."
        case .newFolder: return "문서를 정리할 새 폴더 이름을 입력해 주세요."
        }
    }
}

private enum PortalPDFDocumentAdditionError: Error {
    case invalidLink
    case downloadFailed
    case notPDF
    case photoConversionFailed
}

private struct PortalPDFDocumentDeletionRequest: Identifiable {
    enum Kind: Equatable { case trash, permanent }
    let document: PortalLocalPDFDocument
    let kind: Kind
    var id: String { "\(document.id)-\(kind)" }
}

#Preview {
    PortalPDFDocumentsView()
}
