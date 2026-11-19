//
//  PortalPDFPageNavigatorView.swift
//  NF
//
//  Created by Codex on 8/15/26.
//

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// 페이지 목록 전체화면에 필요한 문서와 최초 선택 페이지를 함께 전달합니다.
struct PortalPDFPageNavigatorPresentation: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let currentPageIndex: Int
    let favoritePageIndexes: Set<Int>
}

/// 전체 페이지 화면에서 PDFPage 참조와 화면상 순서 식별자를 함께 유지합니다.
private struct PortalPDFPageOrganizerItem: Identifiable {
    let id = UUID()
    let page: PDFPage
    var isFavorite: Bool
}

/// 전체 페이지와 즐겨찾기 페이지 목록을 전환하는 상단 탭입니다.
private enum PortalPDFPageNavigatorTab: String, CaseIterable, Identifiable {
    case allPages
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allPages:
            return "전체 리스트"
        case .favorites:
            return "즐겨찾기"
        }
    }
}

/// PDFView 우측에서 전체 페이지를 빠르게 확인하고 이동하는 세로 썸네일 목록입니다.
struct PortalPDFPageSideListView: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let document: PDFDocument
    let currentPageIndex: Int
    let favoritePageIndexes: Set<Int>
    let isPresentedOnLeft: Bool
    let onSelectPage: (Int) -> Void
    let onClose: () -> Void

    @State private var selectedTab: PortalPDFPageNavigatorTab = .allPages

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("전체 페이지")
                        .font(.headline)
                    Text("총 \(document.pageCount)페이지")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("전체 페이지 목록 닫기")
            }
            .foregroundStyle(portalTheme.foregroundColor)
            .padding(12)

            Picker("페이지 목록", selection: $selectedTab) {
                ForEach(PortalPDFPageNavigatorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            Divider()

            ScrollViewReader { proxy in
                Group {
                    if displayedPageIndexes.isEmpty {
                        ContentUnavailableView(
                            "즐겨찾기 페이지가 없습니다",
                            systemImage: "star",
                            description: Text("PDF 설정에서 현재 페이지를 즐겨찾기에 추가해 주세요.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 12) {
                                ForEach(displayedPageIndexes, id: \.self) { pageIndex in
                                    if let page = document.page(at: pageIndex) {
                                        Button {
                                            onSelectPage(pageIndex)
                                        } label: {
                                            PortalPDFPageSideListCell(
                                                page: page,
                                                pageIndex: pageIndex,
                                                isCurrentPage: currentPageIndex == pageIndex,
                                                isFavorite: favoritePageIndexes.contains(pageIndex)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .id(pageIndex)
                                        .accessibilityLabel(
                                            "\(pageIndex + 1) 페이지\(currentPageIndex == pageIndex ? ", 현재 페이지" : ", 이동")\(favoritePageIndexes.contains(pageIndex) ? ", 즐겨찾기" : "")"
                                        )
                                    }
                                }
                            }
                            .padding(12)
                        }
                        .scrollIndicators(.visible)
                    }
                }
                .onAppear {
                    scrollToRelevantPage(using: proxy, animated: false)
                }
                .onChange(of: currentPageIndex) { _, _ in
                    scrollToRelevantPage(using: proxy, animated: true)
                }
                .onChange(of: selectedTab) { _, _ in
                    scrollToRelevantPage(using: proxy, animated: false)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(portalTheme.surfaceColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(portalTheme.borderColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, x: isPresentedOnLeft ? 5 : -5, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PDF \(selectedTab.title)")
    }

    private var displayedPageIndexes: [Int] {
        let allPageIndexes = Array(0..<document.pageCount)
        switch selectedTab {
        case .allPages:
            return allPageIndexes
        case .favorites:
            return allPageIndexes.filter(favoritePageIndexes.contains)
        }
    }

    private func scrollToRelevantPage(using proxy: ScrollViewProxy, animated: Bool) {
        guard let targetPageIndex = displayedPageIndexes.contains(currentPageIndex)
            ? currentPageIndex
            : displayedPageIndexes.first else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(targetPageIndex, anchor: .center)
                }
            } else {
                proxy.scrollTo(targetPageIndex, anchor: .center)
            }
        }
    }
}

/// 우측 빠른 페이지 목록에서 사용하는 가벼운 단일 페이지 썸네일 셀입니다.
private struct PortalPDFPageSideListCell: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let page: PDFPage
    let pageIndex: Int
    let isCurrentPage: Bool
    let isFavorite: Bool

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                } else {
                    ProgressView()
                        .tint(.secondary)
                }
            }
            .frame(height: 132)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isCurrentPage ? portalTheme.accentColor : Color.secondary.opacity(0.24),
                        lineWidth: isCurrentPage ? 3 : 1
                    )
            }

            HStack(spacing: 5) {
                Text("\(pageIndex + 1) 페이지")
                    .font(.caption.weight(isCurrentPage ? .semibold : .regular))
                if isCurrentPage {
                    Image(systemName: "location.circle.fill")
                        .font(.caption)
                        .foregroundStyle(portalTheme.accentColor)
                }
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            .foregroundStyle(portalTheme.foregroundColor)
        }
        .padding(7)
        .background(
            isCurrentPage ? portalTheme.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .task(id: ObjectIdentifier(page)) {
            guard thumbnail == nil else { return }
            await Task.yield()
            thumbnail = page.thumbnail(of: thumbnailSize, for: .cropBox)
        }
    }

    private var thumbnailSize: CGSize {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else {
            return CGSize(width: 180, height: 240)
        }
        let maximumDimension: CGFloat = 300
        let scale = maximumDimension / max(bounds.width, bounds.height)
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

/// 설정에서 전체 PDF 페이지를 확인하고 이동·삭제·복제·순서 변경하는 전체화면입니다.
struct PortalPDFPageNavigatorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.portalAppTheme) private var portalTheme

    let document: PDFDocument
    let currentPage: PDFPage?
    let onSelectPage: (Int) -> Void
    let onDocumentStructureChanged: (Int) -> Void
    let onFavoritePageIndexesChanged: (Set<Int>) -> Void

    @State private var items: [PortalPDFPageOrganizerItem]
    @State private var selectedPageID: UUID?
    @State private var draggedPageID: UUID?
    @State private var isReordering = false
    @State private var selectedTab: PortalPDFPageNavigatorTab = .allPages

    private let columns = [
        GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 16, alignment: .top)
    ]

    init(
        document: PDFDocument,
        currentPageIndex: Int,
        favoritePageIndexes: Set<Int>,
        onSelectPage: @escaping (Int) -> Void,
        onDocumentStructureChanged: @escaping (Int) -> Void,
        onFavoritePageIndexesChanged: @escaping (Set<Int>) -> Void
    ) {
        self.document = document
        let openingPage = document.page(at: currentPageIndex)
        self.currentPage = openingPage
        self.onSelectPage = onSelectPage
        self.onDocumentStructureChanged = onDocumentStructureChanged
        self.onFavoritePageIndexesChanged = onFavoritePageIndexesChanged
        let pages = (0..<document.pageCount).compactMap { pageIndex -> PortalPDFPageOrganizerItem? in
            guard let page = document.page(at: pageIndex) else { return nil }
            return PortalPDFPageOrganizerItem(
                page: page,
                isFavorite: favoritePageIndexes.contains(pageIndex)
            )
        }
        _items = State(initialValue: pages)
        _selectedPageID = State(initialValue: pages.first { $0.page === openingPage }?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("페이지 관리").font(.headline)
                        Text("\(items.count)페이지")
                            .font(.caption)
                            .foregroundStyle(portalTheme.mutedColor)
                    }
                } icon: {
                    Image(systemName: "rectangle.grid.2x2")
                        .foregroundStyle(portalTheme.accentColor)
                }
                Spacer()
                Button(isReordering ? "완료" : "닫기") {
                    if isReordering { finishReordering() }
                    else { dismiss() }
                }
                .buttonStyle(.bordered)
            }
            .padding(16)

            Picker("페이지 목록", selection: $selectedTab) {
                ForEach(PortalPDFPageNavigatorTab.allCases) { tab in
                    Text(tab == .allPages ? "전체" : tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                Group {
                    if displayedItems.isEmpty {
                        ContentUnavailableView("즐겨찾기 페이지가 없습니다", systemImage: "star")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(displayedItems) { item in
                                    organizerCell(for: item).id(item.id)
                                }
                            }
                            .padding(16)
                        }
                    }
                }
                .onAppear { scrollToCurrentPage(using: proxy) }
                .onChange(of: selectedTab) { _, _ in
                    resetInteractionForTabChange()
                    scrollToCurrentPage(using: proxy)
                }
            }
        }
        .foregroundStyle(portalTheme.foregroundColor)
        .background(portalTheme.backgroundColor)
        .tint(portalTheme.accentColor)
        .safeAreaInset(edge: .bottom, spacing: 0) { pageActions }
        .preferredColorScheme(portalTheme.colorScheme)
    }

    private var pageActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isReordering {
                if let index = items.firstIndex(where: { $0.id == selectedPageID }) {
                    Text("\(index + 1)페이지 선택")
                        .font(.caption)
                        .foregroundStyle(portalTheme.mutedColor)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { orderActions; editActions }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { orderActions }
                        HStack { editActions }
                    }
                }
            } else {
                HStack {
                    Button("페이지 편집", systemImage: "pencil") {
                        selectedPageID = selectedPageID ?? displayedItems.first?.id
                        isReordering = true
                    }
                    .disabled(displayedItems.isEmpty)
                    Spacer(minLength: 4)
                    Button("이동", systemImage: "arrow.right", action: moveToSelectedPage)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedPageID == nil)
                }
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(portalTheme.surfaceColor)
        .overlay(alignment: .top) { Rectangle().fill(portalTheme.borderColor).frame(height: 1) }
    }

    private var orderActions: some View {
        Group {
            Button("앞으로", systemImage: "arrow.up") { moveSelectedPage(by: -1) }
                .disabled(neighboringPage(by: -1) == nil)
            Button("뒤로", systemImage: "arrow.down") { moveSelectedPage(by: 1) }
                .disabled(neighboringPage(by: 1) == nil)
        }
    }

    private var editActions: some View {
        Group {
            Button("복제", systemImage: "doc.on.doc", action: duplicateSelectedPage)
                .disabled(selectedPageID == nil)
            Button(role: .destructive, action: deleteSelectedPage) {
                Label("삭제", systemImage: "trash")
            }
            .disabled(selectedPageID == nil || items.count <= 1)
        }
    }

    private func neighboringPage(by offset: Int) -> UUID? {
        let pages = displayedItems
        guard let index = pages.firstIndex(where: { $0.id == selectedPageID }),
              pages.indices.contains(index + offset) else { return nil }
        return pages[index + offset].id
    }

    private func moveSelectedPage(by offset: Int) {
        guard let selectedPageID, let targetID = neighboringPage(by: offset) else { return }
        moveOrganizerPage(&items, from: selectedPageID, to: targetID, tab: selectedTab)
        commitReorderedPages()
    }

    private var displayedItems: [PortalPDFPageOrganizerItem] {
        switch selectedTab {
        case .allPages:
            return items
        case .favorites:
            return items.filter(\.isFavorite)
        }
    }

    private func resetInteractionForTabChange() {
        selectedPageID = nil
        draggedPageID = nil
        isReordering = false
    }

    private func scrollToCurrentPage(using proxy: ScrollViewProxy) {
        guard let currentPage,
              let currentItem = displayedItems.first(where: { $0.page === currentPage }) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(currentItem.id, anchor: .center)
        }
    }

    /// 일반 상태에서는 선택·길게 누르기만 제공하고, 편집 상태에서만 Drag/Drop을 연결합니다.
    @ViewBuilder
    private func organizerCell(for item: PortalPDFPageOrganizerItem) -> some View {
        let content = PortalPDFPageThumbnailCell(
            page: item.page,
            pageIndex: items.firstIndex(where: { $0.id == item.id }) ?? 0,
            isCurrentPage: item.page === currentPage,
            isSelected: selectedPageID == item.id,
            isWiggling: isReordering && selectedPageID == item.id,
            isFavorite: item.isFavorite,
            onToggleFavorite: {
                toggleFavorite(for: item.id)
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPageID = item.id
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            selectedPageID = item.id
            isReordering = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        if isReordering {
            content
                .onDrag {
                    selectedPageID = item.id
                    draggedPageID = item.id
                    return NSItemProvider(object: item.id.uuidString as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: PortalPDFPageDropDelegate(
                        targetID: item.id,
                        items: $items,
                        draggedPageID: $draggedPageID,
                        selectedTab: selectedTab,
                        onDropCompleted: commitReorderedPages
                    )
                )
        } else {
            content
        }
    }

    /// 선택만으로 이동하지 않고 오른쪽 상단 이동 버튼을 눌렀을 때만 PDFView로 돌아갑니다.
    private func moveToSelectedPage() {
        guard let selectedPageID,
              let pageIndex = items.firstIndex(where: { $0.id == selectedPageID }) else { return }
        onSelectPage(pageIndex)
        dismiss()
    }

    /// 페이지 편집 상태를 끝내고 흔들림 및 진행 중 Drag 상태를 정리합니다.
    private func finishReordering() {
        draggedPageID = nil
        isReordering = false
    }

    /// 페이지 카드의 별표를 선택하면 탭과 문서 순서에 맞는 즐겨찾기 번호를 즉시 전달합니다.
    private func toggleFavorite(for itemID: UUID) {
        guard let itemIndex = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[itemIndex].isFavorite.toggle()
        if selectedTab == .favorites, !items[itemIndex].isFavorite {
            selectedPageID = nil
            draggedPageID = nil
            isReordering = false
        }
        publishFavoritePageIndexes()
    }

    /// 마지막 한 페이지는 유지하고 선택 페이지를 문서와 화면 목록에서 함께 삭제합니다.
    private func deleteSelectedPage() {
        guard items.count > 1,
              let selectedPageID,
              let pageIndex = items.firstIndex(where: { $0.id == selectedPageID }) else { return }
        document.removePage(at: pageIndex)
        items.remove(at: pageIndex)
        let nextIndex = min(pageIndex, items.count - 1)
        if selectedTab == .favorites {
            self.selectedPageID = displayedItems.first?.id
        } else {
            self.selectedPageID = items[nextIndex].id
        }
        publishFavoritePageIndexes()
        onDocumentStructureChanged(nextIndex)
    }

    /// 선택 페이지의 편집 주석까지 복제하여 바로 오른쪽 순서에 추가합니다.
    private func duplicateSelectedPage() {
        guard let selectedPageID,
              let pageIndex = items.firstIndex(where: { $0.id == selectedPageID }),
              let data = document.portalEditableDataRepresentation(),
              let copiedDocument = PDFDocument(data: data),
              let copiedPage = copiedDocument.page(at: pageIndex) else { return }
        let insertionIndex = min(pageIndex + 1, items.count)
        document.insert(copiedPage, at: insertionIndex)
        let duplicatedItem = PortalPDFPageOrganizerItem(
            page: copiedPage,
            isFavorite: items[pageIndex].isFavorite
        )
        items.insert(duplicatedItem, at: insertionIndex)
        self.selectedPageID = duplicatedItem.id
        publishFavoritePageIndexes()
        onDocumentStructureChanged(insertionIndex)
    }

    /// Drag 중 확정한 화면 순서대로 PDFDocument의 실제 페이지 순서를 다시 구성합니다.
    private func commitReorderedPages() {
        let orderedPages = items.map(\.page)
        while document.pageCount > 0 {
            document.removePage(at: document.pageCount - 1)
        }
        for (pageIndex, page) in orderedPages.enumerated() {
            document.insert(page, at: pageIndex)
        }
        let selectedIndex = selectedPageID.flatMap { selectedID in
            items.firstIndex(where: { $0.id == selectedID })
        } ?? 0
        publishFavoritePageIndexes()
        onDocumentStructureChanged(selectedIndex)
    }

    private func publishFavoritePageIndexes() {
        let pageIndexes = Set(items.indices.filter { items[$0].isFavorite })
        onFavoritePageIndexesChanged(pageIndexes)
    }
}

/// PDFPage 썸네일을 화면에 나타나는 시점에만 생성해 긴 문서의 최초 표시 비용을 줄입니다.
private struct PortalPDFPageThumbnailCell: View {
    @Environment(\.portalAppTheme) private var portalTheme

    let page: PDFPage
    let pageIndex: Int
    let isCurrentPage: Bool
    let isSelected: Bool
    let isWiggling: Bool
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    @State private var thumbnail: UIImage?
    @State private var wigglePhase = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)

                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    ProgressView()
                        .tint(.secondary)
                }
            }
            .aspectRatio(pageAspectRatio, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? portalTheme.accentColor : Color.secondary.opacity(0.28),
                        lineWidth: isSelected ? 4 : 1
                    )
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, portalTheme.accentColor)
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isFavorite ? portalTheme.accentColor : portalTheme.mutedColor)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel(isFavorite ? "즐겨찾기 해제" : "즐겨찾기 추가")
            }
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)

            HStack(spacing: 5) {
                Text("\(pageIndex + 1) 페이지")
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                if isCurrentPage {
                    Image(systemName: "location.circle.fill")
                        .foregroundStyle(portalTheme.accentColor)
                }
            }
            .foregroundStyle(portalTheme.foregroundColor)
        }
        .rotationEffect(.degrees(isWiggling ? (wigglePhase ? 1.2 : -1.2) : 0))
        .scaleEffect(isWiggling ? 0.98 : 1)
        .onAppear {
            updateWiggleAnimation()
        }
        .onChange(of: isWiggling) { _, _ in
            updateWiggleAnimation()
        }
        .accessibilityLabel(
            "\(pageIndex + 1) 페이지\(isCurrentPage ? ", 현재 페이지" : "")\(isFavorite ? ", 즐겨찾기" : "")\(isSelected ? ", 선택됨" : "")"
        )
        .task(id: ObjectIdentifier(page)) {
            guard thumbnail == nil else { return }
            await Task.yield()
            thumbnail = page.thumbnail(of: thumbnailSize, for: .cropBox)
        }
    }

    private func updateWiggleAnimation() {
        if isWiggling {
            wigglePhase = false
            withAnimation(.easeInOut(duration: 0.12).repeatForever(autoreverses: true)) {
                wigglePhase = true
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                wigglePhase = false
            }
        }
    }

    private var pageAspectRatio: CGFloat {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.height > 0 else { return 0.72 }
        return max(0.35, min(bounds.width / bounds.height, 1.8))
    }

    private var thumbnailSize: CGSize {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else {
            return CGSize(width: 240, height: 320)
        }
        let maximumDimension: CGFloat = 420
        let scale = maximumDimension / max(bounds.width, bounds.height)
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

/// 편집 모드에서 Drag가 다른 페이지 위로 들어오면 목록 순서만 즉시 갱신하고 Drop 시 문서에 확정합니다.
private struct PortalPDFPageDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var items: [PortalPDFPageOrganizerItem]
    @Binding var draggedPageID: UUID?
    let selectedTab: PortalPDFPageNavigatorTab
    let onDropCompleted: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedPageID, draggedPageID != targetID else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            moveOrganizerPage(&items, from: draggedPageID, to: targetID, tab: selectedTab)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedPageID = nil
        onDropCompleted()
        return true
    }

}

private func moveOrganizerPage(
    _ items: inout [PortalPDFPageOrganizerItem],
    from sourceID: UUID,
    to targetID: UUID,
    tab: PortalPDFPageNavigatorTab
) {
    // 즐겨찾기에서 이동해도 일반 페이지의 자리와 PDF 주석 참조는 그대로 유지합니다.
    let slots = items.indices.filter { tab == .allPages || items[$0].isFavorite }
    var pages = slots.map { items[$0] }
    guard let source = pages.firstIndex(where: { $0.id == sourceID }),
          let target = pages.firstIndex(where: { $0.id == targetID }) else { return }
    pages.move(fromOffsets: IndexSet(integer: source), toOffset: target > source ? target + 1 : target)
    for (slot, page) in zip(slots, pages) {
        items[slot] = page
    }
}
