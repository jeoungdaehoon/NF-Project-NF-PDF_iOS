//
// PortalPDFToolbarLayout.swift
// NF
//
// Toolbar placement, sizing, drag, orientation, and panel presentation.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

extension PortalPDFPreviewView {
    /// 현재 선택된 도구에 대응하는 상세 편집 영역이 표시 중인지 여부입니다.
    var isMarkupOptionPanelPresented: Bool {
        (isPenOptionPresented && selectedTool.isInkTool) ||
            (isEraserOptionPresented && selectedTool == .eraser) ||
            ((isShapeAnnotationSelected || isShapeOptionPresented) && selectedTool == .box) ||
            (isTextOptionPresented && selectedTool == .text) ||
            (selectedTool == .image && isImageGalleryPresented)
    }

    /// 선택된 도구에 맞는 상세 편집 영역을 공통 슬롯으로 제공합니다.
    @ViewBuilder
    var activeMarkupOptionPanel: some View {
        if isPenOptionPresented && selectedTool.isInkTool {
            pdfPenOptionPanel
        } else if isEraserOptionPresented && selectedTool == .eraser {
            pdfEraserOptionPanel
        } else if (isShapeAnnotationSelected || isShapeOptionPresented) && selectedTool == .box {
            pdfShapeOptionPanel
        } else if isTextOptionPresented && selectedTool == .text {
            pdfTextOptionPanel
        } else if selectedTool == .image && isImageGalleryPresented {
            pdfImageGalleryPanel
        }
    }

    /**
     편집 알약과 상세 편집 영역의 상대 위치를 계산해 표시합니다.

     - Parameters:
        - containerSize: PDF 편집 화면의 실제 표시 영역 크기입니다.
     - Returns: 편집 알약과 상세 편집 영역을 함께 배치한 오버레이입니다.
     */
    @ViewBuilder
    func pdfMarkupEditorOverlay(in containerSize: CGSize) -> some View {
        ZStack(alignment: .bottom) {
        PortalPDFMarkupDragContainer(
            committedOffset: $markupToolbarOffset,
            liveOffset: $markupToolbarLiveOffset,
            clampOffset: { proposedOffset in
                clampedMarkupToolbarOffset(proposedOffset, in: containerSize)
            },
            onTapMoveButton: {
                toggleMarkupToolbarOrientation()
            }
        ) { moveGesture in
            // 상세 편집창은 overlay로 표시해 기본 편집창의 레이아웃 크기와 위치에 영향을 주지 않습니다.
            pdfMarkupToolbar(moveGesture: moveGesture)
                .overlay(alignment: .leading) {
                    if isMarkupOptionPanelPresented,
                       !isDetachedPenOptionPanelPresented,
                       isMarkupToolbarVertical,
                       shouldPlaceMarkupPanelOnLeft(in: containerSize) {
                        activeMarkupOptionPanel
                            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                            .offset(x: -markupOptionPanelOuterWidth)
                            .offset(penOptionPanelOverlayOffset)
                            .zIndex(3)
                    }
                }
                .overlay(alignment: .trailing) {
                    if isMarkupOptionPanelPresented,
                       !isDetachedPenOptionPanelPresented,
                       isMarkupToolbarVertical,
                       !shouldPlaceMarkupPanelOnLeft(in: containerSize) {
                        activeMarkupOptionPanel
                            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                            .offset(x: markupOptionPanelOuterWidth)
                            .offset(penOptionPanelOverlayOffset)
                            .zIndex(3)
                    }
                }
                .overlay(alignment: .top) {
                    if isMarkupOptionPanelPresented,
                       !isDetachedPenOptionPanelPresented,
                       !isMarkupToolbarVertical,
                       !shouldPlaceMarkupPanelBelow(in: containerSize) {
                        activeMarkupOptionPanel
                            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                            .offset(y: -(markupOptionPanelHeightForOrientation + 5))
                            .offset(penOptionPanelOverlayOffset)
                            .zIndex(3)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isMarkupOptionPanelPresented,
                       !isDetachedPenOptionPanelPresented,
                       !isMarkupToolbarVertical,
                       shouldPlaceMarkupPanelBelow(in: containerSize) {
                        activeMarkupOptionPanel
                            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                            .offset(y: markupOptionPanelHeightForOrientation + 5)
                            .offset(penOptionPanelOverlayOffset)
                            .zIndex(3)
                    }
                }
                .overlay(alignment: .leading) {
                    if isPenEditingPanelPresented,
                       !penOptionPanelDetached,
                       isMarkupToolbarVertical,
                       penEditingPanelPlacement(in: containerSize) == .left {
                        activePenEditingPanel
                            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                            .offset(x: -(markupOptionPanelOuterWidth + penEditingPanelOuterWidth + 5))
                            .zIndex(4)
                    }
                }
                .overlay(alignment: .trailing) {
                    if isPenEditingPanelPresented,
                       !penOptionPanelDetached,
                       isMarkupToolbarVertical,
                       penEditingPanelPlacement(in: containerSize) == .right {
                        activePenEditingPanel
                            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                            .offset(x: markupOptionPanelOuterWidth + penEditingPanelOuterWidth + 5)
                            .zIndex(4)
                    }
                }
                .overlay(alignment: .top) {
                    if isPenEditingPanelPresented,
                       !penOptionPanelDetached,
                       !isMarkupToolbarVertical,
                       penEditingPanelPlacement(in: containerSize) == .top {
                        activePenEditingPanel
                            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                            .offset(y: -(markupOptionPanelHeight + penEditingPanelHeight + 10))
                            .zIndex(4)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isPenEditingPanelPresented,
                       !penOptionPanelDetached,
                       !isMarkupToolbarVertical,
                       penEditingPanelPlacement(in: containerSize) == .bottom {
                        activePenEditingPanel
                            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                            .offset(y: markupOptionPanelHeight + penEditingPanelHeight + 10)
                            .zIndex(4)
                    }
                }
            .animation(.easeInOut(duration: 0.18), value: isMarkupToolbarVertical)
            .animation(
                .spring(response: 0.35, dampingFraction: 0.52, blendDuration: 0.05).delay(0.08),
                value: isMarkupOptionPanelPresented
            )
            .animation(
                .spring(response: 0.35, dampingFraction: 0.52, blendDuration: 0.05).delay(0.08),
                value: editingPenColor
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.72, blendDuration: 0.05), value: selectedTool)
            .animation(
                .spring(response: 0.35, dampingFraction: 0.52, blendDuration: 0.05).delay(0.08),
                value: isPenOptionPresented
            )
            .animation(
                .spring(response: 0.35, dampingFraction: 0.52, blendDuration: 0.05).delay(0.08),
                value: isEraserOptionPresented
            )
            .animation(
                .spring(response: 0.35, dampingFraction: 0.52, blendDuration: 0.05).delay(0.08),
                value: isShapeOptionPresented
            )
            .animation(
                .spring(response: 0.35, dampingFraction: 0.52, blendDuration: 0.05).delay(0.08),
                value: isImageAnnotationSelected
            )
        }
        if isDetachedPenOptionPanelPresented {
            activeMarkupOptionPanel
                .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                .offset(penOptionPanelDetachedAbsoluteDisplayOffset)
                .zIndex(5)
        }
        if isPenEditingPanelPresented, penOptionPanelDetached {
            activePenEditingPanel
                .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                .offset(penOptionPanelDetachedAbsoluteDisplayOffset)
                .offset(penOptionPanelDetachedEditingPanelOffset)
                .zIndex(6)
        }
        }
        .onAppear {
            updateMarkupToolbarContainerSize(containerSize)
        }
        .onChange(of: containerSize) { _, newSize in
            updateMarkupToolbarContainerSize(newSize)
        }
        .onChange(of: isMarkupToolbarVertical) { _, _ in
            normalizeMarkupToolbarOffset()
        }
        .onChange(of: isMarkupOptionPanelPresented) { _, _ in
            // 상세 편집창이 열리거나 닫힐 때도 현재 화면 안쪽 위치를 다시 계산합니다.
            normalizeMarkupToolbarOffset()
        }
    }

    var penOptionPanelDetachedPlacementOffset: CGSize {
        let panelWidth = currentPenOptionPanelSize.width + 10
        let panelHeight = currentPenOptionPanelSize.height
        switch penOptionPanelDetachedPlacement {
        case .left:
            return CGSize(width: -panelWidth, height: 0)
        case .right:
            return CGSize(width: panelWidth, height: 0)
        case .top:
            return CGSize(width: 0, height: -(panelHeight + 5))
        case .bottom:
            return CGSize(width: 0, height: panelHeight + 5)
        }
    }

    /// 이동 버튼을 짧게 누르면 알약 크기를 회전시켜 가로·세로 배치를 자연스럽게 전환합니다.
    func toggleMarkupToolbarOrientation() {
        let rotatedSize = CGSize(width: markupToolbarSize.height, height: markupToolbarSize.width)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.72, blendDuration: 0.05)) {
            isMarkupToolbarVertical.toggle()
            markupToolbarSize = rotatedSize
        }
    }

    /// 기본 편집 툴바에서 상단 타이틀 바만 숨기는 전체화면을 전환합니다.
    func togglePDFEditorFullscreenMode() {
        if isEditingPDFDocumentTitle {
            finishPDFDocumentTitleEditing()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            isPDFEditorFullscreenModeEnabled.toggle()
            isPDFSettingsPresented = false
        }
    }

    /// 현재 PDF 첨부 파일에 연결된 하단 편집 박스 상태를 로컬에 저장합니다.
    func saveMarkupToolbarState() {
        PortalPDFMarkupToolbarStore.save(
            PortalPDFMarkupToolbarStore.Record(
                selectedTool: selectedTool,
                isVertical: isMarkupToolbarVertical,
                offset: markupToolbarOffset,
                size: markupToolbarSize,
                isPenOptionPresented: isPenOptionPresented,
                isShapeOptionPresented: isShapeOptionPresented,
                shapeLineColor: selectedShapeLineColor,
                shapeFillColor: selectedShapeFillColor
            ),
            for: item.url
        )
    }

    /// 현재 PDF 첨부 파일에 저장된 하단 편집 박스 상태를 복원합니다.
    func restoreMarkupToolbarState() {
        guard let record = PortalPDFMarkupToolbarStore.load(for: item.url) else { return }
        selectedTool = record.selectedTool
        isMarkupToolbarVertical = record.isVertical
        markupToolbarOffset = record.offset
        markupToolbarSize = record.size
        isPenOptionPresented = record.selectedTool.isInkTool && isPenPaletteAlwaysVisible
            ? true
            : record.isPenOptionPresented
        isShapeOptionPresented = record.isShapeOptionPresented
        if let shapeLineColor = record.shapeLineColor {
            selectedShapeLineColor = shapeLineColor.color
        }
        if let shapeFillColor = record.shapeFillColor {
            selectedShapeFillColor = shapeFillColor.color
        }
    }

    func resetPDFEditingState() {
        PortalPDFMarkupToolbarStore.remove(for: item.url)
        PortalPDFViewportStore.remove(for: pdfViewportPersistenceIdentifier)
        PortalPDFFavoritePageStore.remove(for: pdfViewportPersistenceIdentifier)
        PortalPDFPenPaletteStore.reset()

        withAnimation(.easeInOut(duration: 0.18)) {
            selectedTool = .view
            isPenOptionPresented = false
            isEraserOptionPresented = false
            isShapeOptionPresented = false
            isTextOptionPresented = false
            selectedShapeType = .rectangle
            selectedShapeLineColor = .orange
            selectedShapeFillColor = .orange.opacity(0.14)
            selectedTextBorderColor = .clear
            selectedTextFillColor = .clear
            selectedTextColor = .black
            selectedPenColor = PortalPDFPenColor.defaults[0]
            penColors = PortalPDFPenColor.defaults
            customizedPenColors = [:]
            customizedPenLineWidths = [:]
            customizedPenPressureStrengths = [:]
            customizedPenStrokeSmoothingStrengths = [:]
            customizedHighlighterColors = [:]
            customizedHighlighterLineWidths = [:]
            didLoadPenPalette = true
            editingPenColor = nil
            editingPenColorValue = .blue
            editingPenLineWidth = 2.4
            editingPenPressureStrength = 1.0
            editingPenStrokeSmoothingStrength = 0.5
            selectedPenLineWidth = 2.4
            isPenPaletteAlwaysVisible = false
            isPDFPresentationModeEnabled = false
            arePDFPresentationControlsVisible = false
            pdfPageControlPositionRawValue = PortalPDFPageControlPosition.right.rawValue
            isPDFPageSideListPresented = false
            isImagePickerPresented = false
            selectedImagePickerItem = nil
            pendingImageAnnotation = nil
            pendingImageEditCommand = nil
            isImageAnnotationSelected = false
            isImageGalleryPresented = false
            photoLibraryItems = []
            photoLibraryMessage = nil
            isShapeAnnotationSelected = false
            pendingShapeAnnotation = nil
            pendingTextAnnotation = nil
            favoritePDFPageIndexes = []
            saveStatus = .idle
            saveErrorMessage = nil
            isMarkupToolbarVertical = false
            markupToolbarOffset = .zero
            markupToolbarLiveOffset = .zero
            markupToolbarSize = CGSize(width: 278, height: 94)
            markupToolbarResizeStartSize = CGSize(width: 278, height: 94)
            isMarkupToolbarResizing = false
            penOptionPanelResizeStartSize = .zero
            isPenOptionPanelResizing = false
            penOptionPanelCommittedSize = .zero
            penOptionPanelCommittedIsVertical = false
            penOptionPanelLiveSize = .zero
            penOptionPanelMoveStartOffset = .zero
            isPenOptionPanelMoving = false
        }

        selectedPenTypeRawValue = PortalPDFPenType.fixed.rawValue
        highlighterLineWidthRaw = 18
        selectedHighlighterCapRawValue = PortalPDFHighlighterCap.round.rawValue
        eraserSizeRaw = 24
        pencilDoubleTapToolRawValue = PortalPDFPencilDoubleTapTool.eraser.rawValue
        penOptionPanelLocked = true
        penOptionPanelHorizontalWidthRaw = 0
        penOptionPanelHorizontalHeightRaw = 0
        penOptionPanelVerticalWidthRaw = 0
        penOptionPanelVerticalHeightRaw = 0
        penOptionPanelHorizontalOffsetXRaw = 0
        penOptionPanelHorizontalOffsetYRaw = 0
        penOptionPanelVerticalOffsetXRaw = 0
        penOptionPanelVerticalOffsetYRaw = 0
        penOptionPanelDetached = false
        penOptionPanelDetachedPlacementRaw = ""
        penOptionPanelDetachedToolbarOffsetXRaw = 0
        penOptionPanelDetachedToolbarOffsetYRaw = 0
        penOptionPanelDetachedWidthRaw = 0
        penOptionPanelDetachedHeightRaw = 0
        penOptionPanelDetachedOffsetXRaw = 0
        penOptionPanelDetachedOffsetYRaw = 0
        penOptionPanelDetachedVerticalRaw = false
        penOptionPanelDetachedScrollVerticalRaw = false
    }

    /// 가로 알약의 위쪽에 상세 패널을 배치할 공간이 부족한지 계산합니다.
    func shouldPlaceMarkupPanelBelow(in containerSize: CGSize) -> Bool {
        // 현재 사용자가 조절한 알약 높이와 상세 패널의 최대 높이를 기준으로 계산합니다.
        let toolbarHeight = currentMarkupToolbarSize.height + 12
        let panelHeight = markupOptionPanelHeight
        let toolbarTop = containerSize.height - toolbarHeight - 12 + currentMarkupToolbarOffset.height
        return toolbarTop - panelHeight - 8 < 0
    }

    /// 상세 편집 패널이 차지하는 실제 높이입니다.
    var markupOptionPanelHeight: CGFloat {
        guard isMarkupOptionPanelPresented else { return 0 }
        switch selectedTool {
        case .box, .text:
            // 선·배경 컬러를 각각 한 개의 ColorPicker로 줄인 현재 패널 높이입니다.
            // 이 값에 기본 편집창과의 5pt 배치 간격을 더해 실제 창 바로 위에 표시합니다.
            return 105
        case .image:
            // 사진 Grid는 두 줄의 썸네일을 표시할 수 있도록 기존 사진 편집창보다 높게 사용합니다.
            return isImageGalleryPresented ? 105 : 62
        case .eraser:
            return 50
        case .pen, .handwriting, .highlighter, .neon:
            return currentPenOptionPanelSize.height
        case .view, .lasso:
            return 0
        }
    }

    enum PenEditingPanelPlacement: String, Equatable {
        case left
        case right
        case top
        case bottom
    }

    /// 세로 알약이 화면 중앙 기준 왼쪽/오른쪽 어느 쪽에 있는지 판단합니다.
    func shouldPlaceMarkupPanelOnLeft(in containerSize: CGSize) -> Bool {
        let leftWidth = markupPanelAvailableContentWidth(onLeft: true, in: containerSize)
        let rightWidth = markupPanelAvailableContentWidth(onLeft: false, in: containerSize)
        let desiredWidth = max(100, min(
            max(currentMarkupToolbarSize.width, currentMarkupToolbarSize.height),
            max(leftWidth, rightWidth)
        ))

        // 현재 방향에서 원하는 최소 폭을 확보하지 못하면 반대편을 먼저 선택합니다.
        if leftWidth >= desiredWidth && rightWidth < desiredWidth { return true }
        if rightWidth >= desiredWidth && leftWidth < desiredWidth { return false }
        return leftWidth >= rightWidth
    }

    /// 세로 모드에서 기본 편집창 옆에 확보 가능한 상세 편집창 콘텐츠 폭입니다.
    func markupPanelAvailableContentWidth(onLeft: Bool, in containerSize: CGSize) -> CGFloat {
        let toolbarWidth = currentMarkupToolbarSize.width + 28
        let toolbarCenterX = (containerSize.width / 2) + currentMarkupToolbarOffset.width
        let toolbarLeading = toolbarCenterX - (toolbarWidth / 2)
        let toolbarTrailing = toolbarCenterX + (toolbarWidth / 2)
        let sideWidth = onLeft
            ? toolbarLeading - 10 - 8
            : containerSize.width - toolbarTrailing - 10 - 8
        return max(0, sideWidth - 10)
    }

    /// 하위 이동 컨테이너가 제스처 종료 후 확정한 편집 알약 위치입니다.
    var currentMarkupToolbarOffset: CGSize {
        markupToolbarOffset
    }

    /// 확정된 알약 크기와 현재 손가락 이동량을 합산한 실시간 외곽 크기입니다.
    var currentMarkupToolbarSize: CGSize {
        clampedMarkupToolbarSize(
            CGSize(
                width: markupToolbarSize.width + markupToolbarResizeTranslation.width,
                height: markupToolbarSize.height + markupToolbarResizeTranslation.height
            ),
            in: markupToolbarContainerSize
        )
    }

    /// PDFView와 동일한 오버레이 좌표계에서 기본 편집창이 차지하는 영역입니다.
    var currentMarkupToolbarFrame: CGRect {
        let toolbarWidth = currentMarkupToolbarSize.width + 28
        let toolbarHeight = currentMarkupToolbarSize.height + 12
        let centerX = (markupToolbarContainerSize.width / 2) + currentMarkupToolbarOffset.width
        let top = markupToolbarContainerSize.height
            - toolbarHeight
            - 12
            + currentMarkupToolbarOffset.height
        return CGRect(
            x: centerX - (toolbarWidth / 2),
            y: top,
            width: toolbarWidth,
            height: toolbarHeight
        )
    }

    /// 상세 편집 박스가 기본 편집 알약의 긴 변보다 넓어지지 않도록 사용할 콘텐츠 폭입니다.
    var markupOptionPanelContentWidth: CGFloat {
        let toolbarLongEdge = max(currentMarkupToolbarSize.width, currentMarkupToolbarSize.height)
        guard isMarkupToolbarVertical && isMarkupOptionPanelPresented else {
            let availableWidth = max(0, markupToolbarContainerSize.width - 10 - 16)
            return max(100, availableWidth > 0 ? min(toolbarLongEdge, availableWidth) : toolbarLongEdge)
        }

        let panelOnLeft = shouldPlaceMarkupPanelOnLeft(in: markupToolbarContainerSize)
        let availableWidth = markupPanelAvailableContentWidth(
            onLeft: panelOnLeft,
            in: markupToolbarContainerSize
        )
        return max(100, min(toolbarLongEdge, availableWidth))
    }

    /// 상세 편집 패널의 외부 여백을 포함한 실제 배치 폭입니다.
    var markupOptionPanelOuterWidth: CGFloat {
        markupOptionPanelWidth + (isMarkupToolbarVertical && selectedTool.isInkTool ? 22 : 10)
    }

    var penOptionPanelAvailableWidth: CGFloat {
        if penOptionPanelDetached {
            return markupToolbarContainerSize.width > 0
                ? max(50, markupToolbarContainerSize.width - 40)
                : 420
        }
        if isMarkupToolbarVertical {
            let panelOnLeft = shouldPlaceMarkupPanelOnLeft(in: markupToolbarContainerSize)
            return max(
                50,
                markupPanelAvailableContentWidth(
                    onLeft: panelOnLeft,
                    in: markupToolbarContainerSize
                )
            )
        }
        return markupToolbarContainerSize.width > 0
            ? max(80, markupToolbarContainerSize.width - (penOptionPanelDetached ? 64 : 32))
            : 320
    }

    var penOptionPanelBaseSize: CGSize {
        let panelIsVertical = penOptionPanelIsVertical
        let defaultWidth: CGFloat = panelIsVertical
            ? 50
            : max(180, min(280, markupToolbarContainerSize.width > 0 ? markupToolbarContainerSize.width - 32 : 240))
        let defaultHeight: CGFloat = panelIsVertical
            ? verticalMarkupToolbarHeight
            : 69
        let storedWidth: Double
        let storedHeight: Double
        if penOptionPanelDetached,
           penOptionPanelDetachedWidthRaw > 0,
           penOptionPanelDetachedHeightRaw > 0 {
            storedWidth = penOptionPanelDetachedWidthRaw
            storedHeight = penOptionPanelDetachedHeightRaw
        } else if panelIsVertical {
            storedWidth = penOptionPanelVerticalWidthRaw
            storedHeight = penOptionPanelVerticalHeightRaw
        } else {
            storedWidth = penOptionPanelHorizontalWidthRaw
            storedHeight = penOptionPanelHorizontalHeightRaw
        }
        if penOptionPanelDetached,
           penOptionPanelDetachedWidthRaw > 0,
           penOptionPanelDetachedHeightRaw > 0 {
            return CGSize(
                width: max(50, CGFloat(penOptionPanelDetachedWidthRaw)),
                height: max(50, CGFloat(penOptionPanelDetachedHeightRaw))
            )
        }
        let maximumHeight = markupToolbarContainerSize.height > 0
            ? max(50, markupToolbarContainerSize.height - (penOptionPanelDetached && !penOptionPanelLocked ? 76 : (penOptionPanelDetached ? 64 : 40)))
            : 420
        let committedSize = penOptionPanelCommittedIsVertical == panelIsVertical
            ? penOptionPanelCommittedSize
            : .zero
        let savedWidth = committedSize.width > 0
            ? committedSize.width
            : (storedWidth > 0 ? CGFloat(storedWidth) : defaultWidth)
        let savedHeight = committedSize.height > 0
            ? committedSize.height
            : (storedHeight > 0 ? CGFloat(storedHeight) : defaultHeight)
        return CGSize(
            width: min(max(savedWidth, 50), penOptionPanelAvailableWidth),
            height: min(max(savedHeight, 50), maximumHeight)
        )
    }

    var currentPenOptionPanelSize: CGSize {
        if isPenOptionPanelResizing, penOptionPanelLiveSize.width > 0, penOptionPanelLiveSize.height > 0 {
            return penOptionPanelLiveSize
        }
        let size = CGSize(
            width: penOptionPanelBaseSize.width,
            height: penOptionPanelBaseSize.height
        )
        return penOptionPanelDetached ? size : clampedPenOptionPanelSize(size)
    }

    var penOptionPanelIsVertical: Bool {
        penOptionPanelDetached ? penOptionPanelDetachedVerticalRaw : isMarkupToolbarVertical
    }

    var penOptionPanelScrollIsVertical: Bool {
        penOptionPanelDetached ? penOptionPanelDetachedScrollVerticalRaw : isMarkupToolbarVertical
    }

    func clampedPenOptionPanelSize(_ size: CGSize) -> CGSize {
        let maximumHeight = markupToolbarContainerSize.height > 0
            ? max(50, markupToolbarContainerSize.height - (penOptionPanelDetached && !penOptionPanelLocked ? 76 : (penOptionPanelDetached ? 64 : 40)))
            : 420
        return CGSize(
            width: min(max(size.width, 50), penOptionPanelAvailableWidth),
            height: min(max(size.height, 50), maximumHeight)
        )
    }

    var penOptionPanelStoredOffset: CGSize {
        penOptionPanelDetached
            ? CGSize(
                width: penOptionPanelDetachedOffsetXRaw,
                height: penOptionPanelDetachedOffsetYRaw
            )
            : (isMarkupToolbarVertical
            ? CGSize(
                width: penOptionPanelVerticalOffsetXRaw,
                height: penOptionPanelVerticalOffsetYRaw
            )
            : CGSize(
                width: penOptionPanelHorizontalOffsetXRaw,
                height: penOptionPanelHorizontalOffsetYRaw
            ))
    }

    var penOptionPanelDetachedToolbarOffset: CGSize {
        CGSize(
            width: penOptionPanelDetachedToolbarOffsetXRaw,
            height: penOptionPanelDetachedToolbarOffsetYRaw
        )
    }

    var penOptionPanelDetachedCompensation: CGSize {
        guard penOptionPanelDetached else { return .zero }
        return CGSize(
            width: penOptionPanelDetachedToolbarOffset.width - markupToolbarLiveOffset.width,
            height: penOptionPanelDetachedToolbarOffset.height - markupToolbarLiveOffset.height
        )
    }

    var isDetachedPenOptionPanelPresented: Bool {
        penOptionPanelDetached && selectedTool.isInkTool && isPenOptionPresented
    }

    var penOptionPanelDetachedPlacement: PenEditingPanelPlacement {
        if let storedPlacement = PenEditingPanelPlacement(rawValue: penOptionPanelDetachedPlacementRaw) {
            return storedPlacement
        }
        if penOptionPanelIsVertical {
            return shouldPlaceMarkupPanelOnLeft(in: markupToolbarContainerSize) ? .left : .right
        }
        return shouldPlaceMarkupPanelBelow(in: markupToolbarContainerSize) ? .bottom : .top
    }

    var penOptionPanelDetachedAbsoluteOffset: CGSize {
        CGSize(
            width: penOptionPanelDetachedToolbarOffset.width + penOptionPanelStoredOffset.width + penOptionPanelMoveTranslation.width,
            height: penOptionPanelDetachedToolbarOffset.height + penOptionPanelStoredOffset.height + penOptionPanelMoveTranslation.height
        )
    }

    var penOptionPanelDetachedAbsoluteDisplayOffset: CGSize {
        let desiredAbsoluteOffset = CGSize(
            width: penOptionPanelDetachedToolbarOffset.width
                + penOptionPanelDetachedPlacementOffset.width
                + penOptionPanelStoredOffset.width
                + penOptionPanelMoveTranslation.width,
            height: penOptionPanelDetachedToolbarOffset.height
                + penOptionPanelDetachedPlacementOffset.height
                + penOptionPanelStoredOffset.height
                + penOptionPanelMoveTranslation.height
        )
        let clampedAbsoluteOffset = clampedDetachedPenOptionPanelAbsoluteOffset(
            desiredAbsoluteOffset,
            in: markupToolbarContainerSize
        )
        return clampedAbsoluteOffset
    }

    var penOptionPanelDetachedEditingPanelOffset: CGSize {
        let containerSize = markupToolbarContainerSize
        let paletteOffset = penOptionPanelDetachedAbsoluteDisplayOffset
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }

        // 잠금 해제 팔레트와 상세창은 모두 하단 정렬 ZStack에 배치됩니다.
        // 따라서 offset만으로 여백을 계산하면 상단에 놓인 팔레트의 상세창이
        // 탭바 영역 위로 밀려날 수 있어, 실제 화면 좌표의 프레임으로 판단합니다.
        let paletteSize = CGSize(
            width: currentPenOptionPanelSize.width + 10,
            height: currentPenOptionPanelSize.height
        )
        let detailSize = CGSize(
            width: penEditingPanelOuterWidth,
            height: penEditingPanelHeight
        )
        let paletteFrame = CGRect(
            x: (containerSize.width - paletteSize.width) / 2 + paletteOffset.width,
            y: containerSize.height - paletteSize.height + paletteOffset.height,
            width: paletteSize.width,
            height: paletteSize.height
        )
        let gap: CGFloat = 5
        let safeFrame = CGRect(origin: .zero, size: containerSize).insetBy(dx: 8, dy: 8)
        let candidates = [
            CGRect(
                x: paletteFrame.maxX + gap,
                y: paletteFrame.maxY - detailSize.height,
                width: detailSize.width,
                height: detailSize.height
            ),
            CGRect(
                x: paletteFrame.minX - gap - detailSize.width,
                y: paletteFrame.maxY - detailSize.height,
                width: detailSize.width,
                height: detailSize.height
            ),
            CGRect(
                x: paletteFrame.midX - detailSize.width / 2,
                y: paletteFrame.maxY + gap,
                width: detailSize.width,
                height: detailSize.height
            ),
            CGRect(
                x: paletteFrame.midX - detailSize.width / 2,
                y: paletteFrame.minY - gap - detailSize.height,
                width: detailSize.width,
                height: detailSize.height
            )
        ]
        let detailFrame = candidates.first(where: { safeFrame.contains($0) })
            ?? clampedPenEditingPanelFrame(candidates[2], to: safeFrame)

        // 상세창의 기본 위치는 컨테이너 하단이므로, 선택한 화면 프레임을
        // 팔레트 offset에 더할 상대 offset으로 다시 변환합니다.
        return CGSize(
            width: detailFrame.midX - (containerSize.width / 2) - paletteOffset.width,
            height: detailFrame.maxY - containerSize.height - paletteOffset.height
        )
    }

    /// 상세창이 팔레트보다 큰 극단적인 화면에서도 화면 경계를 넘지 않게 보정합니다.
    func clampedPenEditingPanelFrame(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        let x = min(max(frame.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(frame.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var penOptionPanelOverlayOffset: CGSize {
        guard selectedTool.isInkTool, isPenOptionPresented else { return .zero }
        return clampedPenOptionPanelOffset(
            CGSize(
                width: penOptionPanelStoredOffset.width + penOptionPanelMoveTranslation.width + penOptionPanelDetachedCompensation.width,
                height: penOptionPanelStoredOffset.height + penOptionPanelMoveTranslation.height + penOptionPanelDetachedCompensation.height
            ),
            in: markupToolbarContainerSize
        )
    }

    func clampedPenOptionPanelOffset(_ offset: CGSize, in containerSize: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0 else { return offset }
        let panelWidth = currentPenOptionPanelSize.width + 64
        let panelHeight = currentPenOptionPanelSize.height
            + (penOptionPanelLocked ? 34 : 76)
        let horizontalLimit = max(0, (containerSize.width - panelWidth) / 2 - 8)
        let verticalLimit = max(0, containerSize.height - panelHeight - 20)
        return CGSize(
            width: min(max(offset.width, -horizontalLimit), horizontalLimit),
            height: min(max(offset.height, -verticalLimit), verticalLimit)
        )
    }

    /// 잠금 해제 팔레트는 하단 정렬 ZStack의 독립 레이어이므로
    /// 기본 편집창처럼 중앙 기준의 대칭 오프셋을 적용하지 않습니다.
    func clampedDetachedPenOptionPanelAbsoluteOffset(
        _ offset: CGSize,
        in containerSize: CGSize
    ) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0 else { return offset }

        let panelWidth = currentPenOptionPanelSize.width + 64
        let panelHeight = currentPenOptionPanelSize.height
        let horizontalLimit = max(0, (containerSize.width - panelWidth) / 2 - 8)
        // 팔레트 Frame 밖으로 실제 돌출되는 조작 UI만 이동 경계에 포함합니다.
        // 기존의 고정 76pt 여유는 팔레트 상단에 불필요한 빈 공간을 만들어
        // 잠금 해제 후에도 PDFView 최상단 약 96pt 아래에서 이동이 멈췄습니다.
        let topControlOverflow: CGFloat = penOptionPanelLocked ? 10 : 14
        let bottomControlOverflow: CGFloat = penOptionPanelLocked ? 0 : 22
        let minimumY = -(containerSize.height - panelHeight - topControlOverflow)
        let maximumY = -bottomControlOverflow

        return CGSize(
            width: min(max(offset.width, -horizontalLimit), horizontalLimit),
            height: min(max(offset.height, minimumY), maximumY)
        )
    }

    var penOptionPanelMoveHandleWidth: CGFloat {
        min(140, max(15, currentPenOptionPanelSize.width * 0.2))
    }

    /// 편집 알약 방향에 맞춘 상세 편집창의 가로 크기입니다.
    var markupOptionPanelWidth: CGFloat {
        if selectedTool.isInkTool && isPenOptionPresented {
            return currentPenOptionPanelSize.width
        }
        if selectedTool == .text {
            return textOptionPanelSize.width
        }
        if !isMarkupToolbarVertical,
           selectedTool == .box || selectedTool == .text || selectedTool == .eraser || (!isMarkupToolbarVertical && selectedTool.isInkTool) {
            return max(180, min(280, markupOptionPanelContentWidth))
        }
        if isMarkupToolbarVertical {
            if selectedTool.isInkTool { return 50 }
            if selectedTool == .box { return 60 }
            if selectedTool == .text { return 60 }
            if selectedTool == .eraser { return 50 }
            return max(60, markupOptionPanelHeight)
        }
        if selectedTool == .eraser {
            return max(240, min(320, markupOptionPanelContentWidth))
        }
        return markupOptionPanelContentWidth
    }

    var isPenEditingPanelPresented: Bool {
        isPenOptionPresented && selectedTool.isInkTool && editingPenColor != nil
    }

    var penEditingPanelHeight: CGFloat {
        if selectedTool == .pen {
            return selectedPenType == .pressure ? 236 : 184
        }
        return 132
    }

    var penEditingPanelWidth: CGFloat {
        if penOptionPanelDetached {
            let availableWidth = markupToolbarContainerSize.width > 0
                ? markupToolbarContainerSize.width - currentPenOptionPanelSize.width - 40
                : 240
            return max(100, min(240, availableWidth))
        }
        if penOptionPanelIsVertical {
            let paletteOnLeft = shouldPlaceMarkupPanelOnLeft(in: markupToolbarContainerSize)
            let availableWidth = markupPanelAvailableContentWidth(
                onLeft: paletteOnLeft,
                in: markupToolbarContainerSize
            ) - markupOptionPanelOuterWidth - 5
            return max(100, min(240, availableWidth))
        } else {
            return max(160, min(280, markupOptionPanelWidth))
        }
    }

    var eraserSize: CGFloat {
        get { CGFloat(min(max(eraserSizeRaw, 12), 64)) }
        set { eraserSizeRaw = Double(min(max(newValue, 12), 64)) }
    }

    var penEditingPanelOuterWidth: CGFloat {
        penEditingPanelWidth + 10
    }

    func penEditingPanelPlacement(in containerSize: CGSize) -> PenEditingPanelPlacement {
        guard isMarkupToolbarVertical else {
            // 컬러 팔레트가 위에 있으면 그 위로, 아래에 있으면 그 아래로 바로 이어 붙입니다.
            return shouldPlaceMarkupPanelBelow(in: containerSize) ? .bottom : .top
        }

        let leftWidth = markupPanelAvailableContentWidth(onLeft: true, in: containerSize)
        let rightWidth = markupPanelAvailableContentWidth(onLeft: false, in: containerSize)
        let paletteOnLeft = shouldPlaceMarkupPanelOnLeft(in: containerSize)

        let requiredSideWidth = markupOptionPanelOuterWidth + penEditingPanelWidth + 5

        // 팔레트가 있는 같은 방향의 바깥쪽에 상세창을 바로 이어 붙입니다.
        if paletteOnLeft, leftWidth >= requiredSideWidth { return .left }
        if !paletteOnLeft, rightWidth >= requiredSideWidth { return .right }

        // 좌우 공간이 부족한 경우에는 팔레트가 없는 상·하 공간으로 이동합니다.
        let toolbarHeight = currentMarkupToolbarSize.height + 12
        let toolbarTop = containerSize.height - toolbarHeight - 12 + currentMarkupToolbarOffset.height
        let topSpace = max(0, toolbarTop - 8)
        return topSpace >= penEditingPanelHeight ? .top : .bottom
    }

    /// 편집 알약 방향에 맞춘 상세 편집창의 세로 크기입니다.
    var markupOptionPanelHeightForOrientation: CGFloat {
        if selectedTool.isInkTool && isPenOptionPresented {
            return currentPenOptionPanelSize.height
        }
        if selectedTool == .text {
            return textOptionPanelSize.height
        }
        return isMarkupToolbarVertical
            ? verticalMarkupToolbarHeight
            : markupOptionPanelHeight
    }

    /// 문자 상세 편집창은 기본 툴바 크기가 아닌 내부 컬러 2개와 추가 버튼 크기에 맞춥니다.
    var textOptionPanelSize: CGSize {
        isMarkupToolbarVertical
            ? CGSize(width: 68, height: 230)
            : CGSize(width: 200, height: 68)
    }

    /// 세로 기본 편집창이 화면에서 실제로 차지하는 높이입니다.
    /// 기본 알약의 높이에 하단 배치 여백을 포함해 상세 편집창과 동일한 기준을 사용합니다.
    var verticalMarkupToolbarHeight: CGFloat {
        currentMarkupToolbarSize.height + 12
    }

    /// 편집 알약이 현재 화면 경계를 벗어나지 않도록 이동 오프셋을 제한합니다.
    func clampedMarkupToolbarOffset(_ offset: CGSize, in containerSize: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0 else { return offset }

        // 기본 편집창 자체만 기준으로 제한해 상세 편집창이 열려도 기본 위치를 유지합니다.
        let toolbarWidth = currentMarkupToolbarSize.width + 28
        let toolbarHeight = currentMarkupToolbarSize.height + 12
        let horizontalLimit = max(0, (containerSize.width - toolbarWidth) / 2 - 8)
        let topSafeInset: CGFloat = isMarkupToolbarVertical ? 24 : 64
        let verticalTopLimit = -max(0, containerSize.height - toolbarHeight - topSafeInset)

        return CGSize(
            // 좌우 어느 쪽으로 이동해도 알약 전체가 최소 8pt는 화면 안에 남도록 제한합니다.
            width: min(max(offset.width, -horizontalLimit), horizontalLimit),
            // 기본 하단 위치보다 아래로 내려가 가려지지 않도록 위쪽 이동만 허용합니다.
            height: min(max(offset.height, verticalTopLimit), 0)
        )
    }

    /// 화면 크기가 바뀌거나 상세 편집창 상태가 바뀐 뒤 확정 위치를 화면 안쪽으로 보정합니다.
    func normalizeMarkupToolbarOffset() {
        guard markupToolbarContainerSize.width > 0, markupToolbarContainerSize.height > 0 else { return }
        markupToolbarOffset = clampedMarkupToolbarOffset(markupToolbarOffset, in: markupToolbarContainerSize)
        markupToolbarSize = clampedMarkupToolbarSize(markupToolbarSize, in: markupToolbarContainerSize)
    }

    /// GeometryReader에서 전달된 최신 화면 크기를 저장하고 기존 위치를 보정합니다.
    func updateMarkupToolbarContainerSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        markupToolbarContainerSize = size
        normalizeMarkupToolbarOffset()
    }

    /// 화면 사방 20pt 여백과 최소 세 개 버튼 표시 규칙을 적용해 알약 크기를 제한합니다.
    func clampedMarkupToolbarSize(_ size: CGSize, in containerSize: CGSize) -> CGSize {
        let buttonLength: CGFloat = 40
        let contentPadding: CGFloat = 8
        let gridCrossAxisLength = buttonLength + contentPadding
        // 현재 편집창 크기에 따라 행·열 수가 자동으로 바뀌도록 아이콘 한 칸만 확보합니다.
        let minimumSize = isMarkupToolbarVertical
            ? CGSize(width: gridCrossAxisLength, height: gridCrossAxisLength)
            : CGSize(width: gridCrossAxisLength, height: gridCrossAxisLength)

        guard containerSize.width > 0, containerSize.height > 0 else {
            return CGSize(
                width: max(minimumSize.width, size.width),
                height: max(minimumSize.height, size.height)
            )
        }

        // 알약 전체가 화면 사방 20pt 안전 여백 안에 들어오도록 최대 크기를 계산합니다.
        let maximumSize = CGSize(
            width: max(minimumSize.width, containerSize.width - 40),
            height: max(minimumSize.height, containerSize.height - 40)
        )
        return CGSize(
            width: min(max(size.width, minimumSize.width), maximumSize.width),
            height: min(max(size.height, minimumSize.height), maximumSize.height)
        )
    }

    /// 현재 로드된 PDFDocument 입니다.
    var loadedDocument: PDFDocument? {
        if case .loaded(let document) = state {
            return document
        }
        return nil
    }

    /// 로컬 문서 또는 서버 저장 API 문서가 편집 저장을 지원하는지 여부입니다.
    var canSavePDFDocument: Bool {
        loadedDocument != nil && (item.localFileURL != nil || item.url.path.hasPrefix("/api/artifacts/files"))
    }

    /// 설정에서 로컬 저장을 켰거나 문서 라이브러리에서 직접 연 PDF인지 여부입니다.
    var shouldUseLocalPDFFile: Bool {
        isPDFLocalStorageEnabled || item.localFileURL != nil
    }

    /// 파일명이 변경되어도 같은 로컬 문서의 확대·스크롤 위치를 찾을 수 있는 식별자입니다.
    var pdfViewportPersistenceIdentifier: String {
        item.localDocumentID ?? item.url.absoluteString
    }

    /// PDF 로딩 중 사용자에게 표시할 진행 화면입니다.
    var loadingView: some View {
        VStack(spacing: 14) {
            if let localDownloadProgress {
                ProgressView(value: localDownloadProgress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(NFColor.blue)
                    .frame(maxWidth: 320)
                Text("\(Int((localDownloadProgress * 100).rounded()))%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            } else {
                ProgressView()
                    .tint(.white)
            }
            Text(localDownloadProgress == nil ? "첨부 파일을 확인하고 있습니다." : "PDF를 기기에 저장하고 있습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /** 로컬에 없는 PDF의 설정 상태에 맞는 최초 안내 팝업을 구성합니다. */
    func initialOpenAlert(for prompt: PortalPDFInitialOpenPrompt) -> Alert {
        switch prompt {
        case .localStorageEnabled:
            return Alert(
                title: Text("PDF를 로컬에 저장할까요?"),
                message: Text("파일을 기기에 저장하면 더 빠르게 열고 편집할 수 있습니다. 저장된 문서는 ‘문서 > 파일 리스트’에서 다시 확인할 수 있습니다."),
                primaryButton: .default(Text("확인")) {
                    Task { await downloadAndOpenPDF(saveLocally: true) }
                },
                secondaryButton: .cancel(Text("취소")) {
                    dismiss()
                }
            )
        case .localStorageDisabled:
            return Alert(
                title: Text("PDF 파일 저장"),
                message: Text("로컬 파일 저장을 켜면 PDF를 빠르게 다시 열고 편집 내용을 기기에서 관리할 수 있습니다. 저장된 문서는 ‘문서 > 파일 리스트’에서 확인할 수 있습니다."),
                primaryButton: .default(Text("파일 저장")) {
                    isPDFLocalStorageEnabled = true
                    onPDFLocalStorageEnabled()
                    Task { @MainActor in
                        await Task.yield()
                        initialOpenPrompt = .localStorageEnabled
                    }
                },
                secondaryButton: .default(Text("바로 보기")) {
                    Task { await downloadAndOpenPDF(saveLocally: false) }
                }
            )
        }
    }

    /// PDF 편집 도구 선택을 위한 하단 도구 영역입니다.
}
