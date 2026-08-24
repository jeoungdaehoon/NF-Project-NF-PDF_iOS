//
//  PortalPDFCloudCenterView.swift
//  NF
//
//  Created by Codex on 8/24/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct PortalPDFCloudCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.portalAppTheme) private var portalTheme

    private let localRepository = PortalPDFLocalStorageRepository()
    private let iCloudRepository = PortalPDFICloudRepository()
    private let googleDriveService = PortalPDFGoogleDriveService()

    @State private var selectedProvider: PortalPDFCloudProvider = .iCloud
    @State private var localDocuments: [PortalLocalPDFDocument] = []
    @State private var iCloudDocuments: [PortalICloudPDFDocument] = []
    @State private var googleDriveLinks: [PortalPDFGoogleDriveLink] = []
    @State private var iCloudAvailability: PortalICloudAvailability = .checking
    @State private var processingID: String?
    @State private var isFileImporterPresented = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    PortalPDFCloudHeaderView()
                    providerPicker
                    providerStatusCard
                    if selectedProvider == .iCloud {
                        iCloudContent
                    } else {
                        googleDriveContent
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .background(portalTheme.documentLibraryBackgroundColor.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: dismiss.callAsFunction) {
                        Image(systemName: "chevron.left")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("문서로 돌아가기")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(processingID != nil)
                    .accessibilityLabel("클라우드 새로고침")
                }
            }
            .toolbarBackground(portalTheme.documentLibraryBackgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(portalTheme.colorScheme, for: .navigationBar)
            .tint(portalTheme.accentColor)
            .task {
                await reload()
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false,
                onCompletion: importProviderDocument
            )
            .alert("클라우드 연동 실패", isPresented: errorAlertBinding) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "클라우드 작업을 완료하지 못했습니다.")
            }
            .alert("클라우드 연동 완료", isPresented: successAlertBinding) {
                Button("확인", role: .cancel) { successMessage = nil }
            } message: {
                Text(successMessage ?? "동기화를 완료했습니다.")
            }
        }
        .background(portalTheme.documentLibraryBackgroundColor.ignoresSafeArea())
        .preferredColorScheme(portalTheme.colorScheme)
    }

    private var providerPicker: some View {
        Picker("클라우드 저장소", selection: $selectedProvider) {
            ForEach(PortalPDFCloudProvider.allCases) { provider in
                Label(provider.title, systemImage: provider.systemImageName)
                    .tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("클라우드 저장소 선택")
    }

    private var providerStatusCard: some View {
        PortalPDFCloudStatusCard(
            provider: selectedProvider,
            title: providerStatusTitle,
            message: providerStatusMessage,
            isAvailable: providerIsAvailable,
            actionTitle: selectedProvider == .googleDrive ? "Drive에서 가져오기" : nil,
            action: selectedProvider == .googleDrive ? { isFileImporterPresented = true } : nil
        )
    }

    @ViewBuilder
    private var iCloudContent: some View {
        PortalPDFCloudSectionTitle(
            title: "기기 문서",
            subtitle: "편집본을 iCloud Drive의 NF PDF 폴더에 저장합니다."
        )
        if localDocuments.isEmpty {
            PortalPDFCloudEmptyCard(
                title: "동기화할 문서가 없습니다",
                message: "문서 화면에서 PDF를 먼저 추가해 주세요.",
                systemImage: "doc.badge.plus"
            )
        } else {
            ForEach(localDocuments.filter { !$0.isDeleted }) { document in
                PortalPDFCloudLocalDocumentRow(
                    document: document,
                    provider: .iCloud,
                    isSynced: iCloudDocuments.contains { $0.localDocumentID == document.id },
                    isProcessing: processingID == document.id,
                    onSync: { syncToICloud(document) }
                )
            }
        }

        PortalPDFCloudSectionTitle(
            title: "iCloud 문서",
            subtitle: "다른 기기에서 저장한 PDF를 이 기기의 NF 문서로 가져올 수 있습니다."
        )
        if iCloudDocuments.isEmpty {
            PortalPDFCloudEmptyCard(
                title: "iCloud PDF가 없습니다",
                message: iCloudAvailability.message,
                systemImage: "icloud"
            )
        } else {
            ForEach(iCloudDocuments) { document in
                PortalPDFICloudDocumentRow(
                    document: document,
                    isProcessing: processingID == document.id,
                    onImport: { importFromICloud(document) },
                    onDelete: { deleteFromICloud(document) }
                )
            }
        }
    }

    @ViewBuilder
    private var googleDriveContent: some View {
        PortalPDFCloudSectionTitle(
            title: "NF 계정 문서",
            subtitle: "NF에 Google로 로그인한 계정의 Notefree 폴더에 저장합니다."
        )
        if localDocuments.isEmpty {
            PortalPDFCloudEmptyCard(
                title: "동기화할 문서가 없습니다",
                message: "문서 화면에서 PDF를 먼저 추가해 주세요.",
                systemImage: "doc.badge.plus"
            )
        } else {
            ForEach(localDocuments.filter { !$0.isDeleted }) { document in
                let link = googleDriveLinks.first { $0.localDocumentID == document.id }
                PortalPDFCloudLocalDocumentRow(
                    document: document,
                    provider: .googleDrive,
                    isSynced: link != nil,
                    lastSyncedAt: link?.syncedAt,
                    isProcessing: processingID == document.id,
                    onSync: { syncToGoogleDrive(document) }
                )
            }
        }

        PortalPDFCloudSectionTitle(
            title: "Drive 연결 상태",
            subtitle: "연결 기록은 Drive 토큰이 아니라 NF 파일 ID만 기기에 보관합니다."
        )
        if googleDriveLinks.isEmpty {
            PortalPDFCloudEmptyCard(
                title: "연결된 Drive 문서가 없습니다",
                message: "기기 문서에서 Google Drive 저장을 선택해 주세요.",
                systemImage: "externaldrive"
            )
        } else {
            ForEach(googleDriveLinks) { link in
                PortalPDFGoogleDriveLinkRow(link: link)
            }
        }
    }

    private var providerStatusTitle: String {
        switch selectedProvider {
        case .iCloud:
            iCloudAvailability == .available ? "iCloud Drive 연결됨" : "iCloud Drive 확인 필요"
        case .googleDrive:
            "NF 로그인 계정으로 연결"
        }
    }

    private var providerStatusMessage: String {
        switch selectedProvider {
        case .iCloud:
            iCloudAvailability.message
        case .googleDrive:
            "별도 Google 로그인 없이 현재 NF 포털 세션을 사용합니다. Drive 권한이 만료된 경우 NF에서 다시 로그인해 주세요."
        }
    }

    private var providerIsAvailable: Bool {
        switch selectedProvider {
        case .iCloud: iCloudAvailability == .available
        case .googleDrive: true
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var successAlertBinding: Binding<Bool> {
        Binding(
            get: { successMessage != nil },
            set: { if !$0 { successMessage = nil } }
        )
    }

    @MainActor
    private func reload() async {
        localDocuments = localRepository.documents()
        googleDriveLinks = googleDriveService.links()
        iCloudAvailability = await iCloudRepository.availability()
        guard iCloudAvailability == .available else {
            iCloudDocuments = []
            return
        }
        do {
            iCloudDocuments = try await iCloudRepository.documents()
        } catch {
            errorMessage = cloudErrorMessage(error)
        }
    }

    private func syncToICloud(_ document: PortalLocalPDFDocument) {
        Task {
            processingID = document.id
            defer { processingID = nil }
            do {
                _ = try await iCloudRepository.upload(document)
                await reload()
                successMessage = "“\(document.fileName)” 문서를 iCloud Drive에 저장했습니다."
            } catch {
                errorMessage = cloudErrorMessage(error)
            }
        }
    }

    private func syncToGoogleDrive(_ document: PortalLocalPDFDocument) {
        Task {
            processingID = document.id
            defer { processingID = nil }
            do {
                _ = try await googleDriveService.sync(document)
                googleDriveLinks = googleDriveService.links()
                successMessage = "“\(document.fileName)” 문서를 NF 로그인 계정의 Google Drive에 저장했습니다."
            } catch {
                errorMessage = cloudErrorMessage(error)
            }
        }
    }

    private func importFromICloud(_ document: PortalICloudPDFDocument) {
        Task {
            processingID = document.id
            defer { processingID = nil }
            do {
                let data = try await iCloudRepository.data(for: document)
                if let localDocumentID = document.localDocumentID,
                   let existing = localRepository.documents().first(where: { $0.id == localDocumentID }) {
                    try localRepository.save(data, for: PortalAttachmentPreviewItem(localDocument: existing))
                } else {
                    _ = try localRepository.createDocument(data: data, fileName: document.fileName)
                }
                localDocuments = localRepository.documents()
                successMessage = "“\(document.fileName)” 문서를 이 기기로 가져왔습니다."
            } catch {
                errorMessage = cloudErrorMessage(error)
            }
        }
    }

    private func deleteFromICloud(_ document: PortalICloudPDFDocument) {
        Task {
            processingID = document.id
            defer { processingID = nil }
            do {
                try await iCloudRepository.delete(document)
                iCloudDocuments = try await iCloudRepository.documents()
            } catch {
                errorMessage = cloudErrorMessage(error)
            }
        }
    }

    private func importProviderDocument(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result,
               (error as? CocoaError)?.code != .userCancelled {
                errorMessage = "파일 제공자에서 PDF 문서를 가져오지 못했습니다."
            }
            return
        }
        Task {
            processingID = url.absoluteString
            defer { processingID = nil }
            do {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                _ = try localRepository.createDocument(data: data, fileName: url.lastPathComponent)
                localDocuments = localRepository.documents()
                successMessage = "“\(url.lastPathComponent)” 문서를 NF에 가져왔습니다."
            } catch {
                errorMessage = "선택한 PDF 문서를 가져오지 못했습니다."
            }
        }
    }

    private func cloudErrorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "클라우드 작업을 완료하지 못했습니다. 네트워크 연결을 확인해 주세요."
    }
}

private struct PortalPDFCloudHeaderView: View {
    @Environment(\.portalAppTheme) private var portalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("클라우드")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(portalTheme.foregroundColor)
            Text("NF PDF를 iCloud와 로그인한 Google 계정에서 안전하게 이어서 사용합니다.")
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
}

private struct PortalPDFCloudStatusCard: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let provider: PortalPDFCloudProvider
    let title: String
    let message: String
    let isAvailable: Bool
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: provider.systemImageName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isAvailable ? portalTheme.accentColor : portalTheme.mutedColor)
                .frame(width: 42, height: 42)
                .background(portalTheme.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isAvailable ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(portalTheme.foregroundColor)
                }
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(portalTheme.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.system(size: 13, weight: .semibold))
                        .buttonStyle(.bordered)
                        .tint(portalTheme.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(portalTheme.documentLibraryCardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(portalTheme.borderColor.opacity(0.9), lineWidth: 1)
        }
    }
}

private struct PortalPDFCloudSectionTitle: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(portalTheme.foregroundColor)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(portalTheme.mutedColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}

private struct PortalPDFCloudLocalDocumentRow: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let document: PortalLocalPDFDocument
    let provider: PortalPDFCloudProvider
    let isSynced: Bool
    var lastSyncedAt: Date?
    let isProcessing: Bool
    let onSync: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: isSynced ? "checkmark.icloud.fill" : "doc.richtext.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isSynced ? Color.green : portalTheme.accentColor)
                .frame(width: 42, height: 46)
                .background(portalTheme.accentColor.opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(document.fileName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(portalTheme.foregroundColor)
                    .lineLimit(2)
                Text(syncDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(portalTheme.mutedColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onSync) {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(isSynced ? "업데이트" : "저장")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .tint(portalTheme.accentColor)
            .disabled(isProcessing)
            .accessibilityLabel("\(document.fileName) \(provider.title)에 저장")
        }
        .padding(14)
        .background(portalTheme.documentLibraryCardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(portalTheme.borderColor.opacity(0.9), lineWidth: 1)
        }
    }

    private var syncDetail: String {
        if let lastSyncedAt {
            return "마지막 동기화 \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return isSynced ? "\(provider.title)에 저장됨" : "이 기기에만 저장됨"
    }
}

private struct PortalPDFICloudDocumentRow: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let document: PortalICloudPDFDocument
    let isProcessing: Bool
    let onImport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: document.isDownloaded ? "icloud.and.arrow.down.fill" : "icloud")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(portalTheme.accentColor)
                .frame(width: 42, height: 46)
                .background(portalTheme.accentColor.opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(document.fileName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(portalTheme.foregroundColor)
                    .lineLimit(2)
                Text(metadata)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(portalTheme.mutedColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button(action: onImport) {
                    Label("기기로 가져오기", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("iCloud에서 삭제", systemImage: "trash")
                }
            } label: {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .disabled(isProcessing)
            .accessibilityLabel("\(document.fileName) 더보기")
        }
        .padding(14)
        .background(portalTheme.documentLibraryCardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(portalTheme.borderColor.opacity(0.9), lineWidth: 1)
        }
    }

    private var metadata: String {
        let size = ByteCountFormatter.string(fromByteCount: document.fileSize, countStyle: .file)
        let state = document.isUploaded ? "업로드 완료" : "업로드 중"
        return "\(state) · \(size) · \(document.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct PortalPDFGoogleDriveLinkRow: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let link: PortalPDFGoogleDriveLink

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.green)
                .frame(width: 42, height: 46)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(link.fileName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(portalTheme.foregroundColor)
                    .lineLimit(2)
                Text("Drive 동기화 \(link.syncedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(portalTheme.mutedColor)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .accessibilityLabel("동기화 완료")
        }
        .padding(14)
        .background(portalTheme.documentLibraryCardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(portalTheme.borderColor.opacity(0.9), lineWidth: 1)
        }
    }
}

private struct PortalPDFCloudEmptyCard: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(portalTheme.mutedColor)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(portalTheme.foregroundColor)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(portalTheme.mutedColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .background(portalTheme.documentLibraryCardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(portalTheme.borderColor.opacity(0.9), lineWidth: 1)
        }
    }
}
