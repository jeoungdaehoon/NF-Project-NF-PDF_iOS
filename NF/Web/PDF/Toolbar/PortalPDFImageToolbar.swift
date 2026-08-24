//
// PortalPDFImageToolbar.swift
// NF
//
// Image insertion, editing, selection, and tool activation controls.
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
    var pdfImageGalleryPanel: some View {
        Group {
            if isMarkupToolbarVertical {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 40), spacing: 6),
                            GridItem(.flexible(minimum: 40), spacing: 6)
                        ],
                        spacing: 6
                    ) {
                        photoLibraryAddButton
                        photoLibraryGridContent
                    }
                    .padding(8)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [
                            GridItem(.flexible(minimum: 40), spacing: 6),
                            GridItem(.flexible(minimum: 40), spacing: 6)
                        ],
                        spacing: 6
                    ) {
                        photoLibraryAddButton
                        photoLibraryGridContent
                    }
                    .padding(8)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(width: markupOptionPanelWidth, height: markupOptionPanelHeightForOrientation)
        .background(inverseEditorBlurBackground(cornerRadius: 18))
        .padding(.horizontal, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("사진첩 사진 Grid")
    }

    /// 사진첩 Grid에서 실제 시스템 사진첩 선택창으로 이동하는 첫 번째 타일입니다.
    var photoLibraryAddButton: some View {
        Button {
            imagePickerPurpose = .insert
            isImageGalleryPresented = false
            isImagePickerPresented = true
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 18, weight: .bold))
                Text("추가")
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(width: 40, height: 40)
            .foregroundStyle(Color.white)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("사진첩 열기")
    }

    /// 사진첩 Grid의 개별 썸네일입니다. 탭하면 해당 사진을 PDF에 빠르게 삽입합니다.
    func photoLibraryItemButton(_ item: PortalPhotoLibraryItem) -> some View {
        Button {
            Task { @MainActor in
                guard let image = await loadPhotoAssetImage(item.asset, targetSize: CGSize(width: 160, height: 160)) else {
                    return
                }
                pendingImageAnnotation = PortalPDFPendingImage(image: image)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72, blendDuration: 0.05)) {
                    isImageGalleryPresented = false
                }
            }
        } label: {
            Image(uiImage: item.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("사진첩 사진 추가")
    }

    /// 사진첩을 아직 읽지 못했거나 접근이 제한된 상태를 Grid 안에서 안내합니다.
    @ViewBuilder
    var photoLibraryEmptyState: some View {
        if isPhotoLibraryLoading {
            ProgressView()
                .tint(.white)
                .frame(width: markupOptionPanelWidth - 16, height: 40)
        } else {
            Text(photoLibraryMessage ?? "사진첩에 표시할 사진이 없습니다.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: markupOptionPanelWidth - 24, height: 40)
        }
    }

    /// 사진첩 목록이 비어 있을 때도 추가 버튼과 안내 문구가 함께 보이도록 구성합니다.
    @ViewBuilder
    var photoLibraryGridContent: some View {
        if photoLibraryItems.isEmpty {
            photoLibraryEmptyState
        } else {
            ForEach(photoLibraryItems) { item in
                photoLibraryItemButton(item)
            }
        }
    }

    /// 이미지 말풍선 메뉴에서 선택한 기능을 기존 이미지 편집 명령 흐름으로 전달합니다.
    func handleImageAction(_ action: PortalPDFImageAction) {
        switch action {
        case .replace:
            imagePickerPurpose = .replace
            isImagePickerPresented = true
        case .resetSize:
            pendingImageEditCommand = PortalPDFImageEditCommand(operation: .resetSize)
        case .rotateClockwise:
            pendingImageEditCommand = PortalPDFImageEditCommand(operation: .rotateClockwise)
        case .flipHorizontal:
            pendingImageEditCommand = PortalPDFImageEditCommand(operation: .flipHorizontal)
        case .crop:
            pendingImageEditCommand = PortalPDFImageEditCommand(operation: .openCropEditor)
        case .openSystemEditor:
            pendingImageEditCommand = PortalPDFImageEditCommand(operation: .openSystemEditor)
        case .bringToFront:
            pendingImageEditCommand = PortalPDFImageEditCommand(operation: .bringToFront)
        case .sendToBack:
            pendingImageEditCommand = PortalPDFImageEditCommand(operation: .sendToBack)
        }
    }

    /**
     하단 PDF 편집 도구 버튼 선택을 처리합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - tool: 사용자가 선택한 PDF 편집 도구입니다.
     */
    func selectMarkupTool(_ tool: PortalPDFMarkupTool) {
        if tool == .eraser, selectedTool == .eraser {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72, blendDuration: 0.05)) {
                isEraserOptionPresented.toggle()
            }
            return
        }
        if tool.isInkTool, selectedTool == tool {
            if isPenPaletteAlwaysVisible {
                isPenOptionPresented = true
                return
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72, blendDuration: 0.05)) {
                isPenOptionPresented.toggle()
            }
            return
        }
        if tool == .box, selectedTool == .box {
            // 선택된 박스가 있으면 선택 상태가 창을 계속 표시합니다.
            // 선택된 박스가 없을 때만 두 번째 탭으로 새 박스 옵션창을 엽니다.
            if !isShapeAnnotationSelected {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.72, blendDuration: 0.05)) {
                    isShapeOptionPresented.toggle()
                }
            }
            return
        }
        if tool == .image, selectedTool == .image {
            // 사진 도구를 다시 선택하면 실제 기기 사진첩의 최근 사진을 Grid 팝업으로 보여줍니다.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72, blendDuration: 0.05)) {
                isImageGalleryPresented.toggle()
            }
            return
        }
        if tool == .text, selectedTool == .text {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72, blendDuration: 0.05)) {
                isTextOptionPresented.toggle()
            }
            return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.72, blendDuration: 0.05)) {
            selectedTool = tool
            isPenOptionPresented = tool.isInkTool && isPenPaletteAlwaysVisible
            isEraserOptionPresented = false
            isShapeOptionPresented = false
            isTextOptionPresented = tool == .text
            isImageGalleryPresented = false
            if tool != .image {
                isImageAnnotationSelected = false
            }
            if tool != .box {
                isShapeAnnotationSelected = false
            }
        }
    }

    /// 항상 표시 설정이 켜진 동안 펜 계열 도구의 팔레트가 닫히지 않도록 보정합니다.
    func enforceAlwaysVisiblePenPaletteIfNeeded() {
        guard isPenPaletteAlwaysVisible, selectedTool.isInkTool else { return }
        isPenOptionPresented = true
    }

    /**
     PDF 이미지 주석을 길게 눌렀을 때 하단 도구 상태를 이미지 편집 모드로 맞춥니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     */
    func activateImageEditMode() {
        selectedTool = .image
        isPenOptionPresented = false
        isEraserOptionPresented = false
        isShapeOptionPresented = false
        isTextOptionPresented = false
        isImageGalleryPresented = false
        isShapeAnnotationSelected = false
    }

    /// PDF 도형을 길게 눌렀을 때 박스 편집 모드로 전환합니다.
    func activateShapeEditMode() {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedTool = .box
            isPenOptionPresented = false
            isEraserOptionPresented = false
            isShapeOptionPresented = false
            isTextOptionPresented = false
            isImageAnnotationSelected = false
            isImageGalleryPresented = false
            isShapeAnnotationSelected = false
        }
    }

    /// 이미지·박스 편집 모드에서 텍스트 박스를 선택하면 텍스트 편집 도구로 전환합니다.
    func activateTextEditMode() {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedTool = .text
            isPenOptionPresented = false
            isEraserOptionPresented = false
            isShapeOptionPresented = false
            isTextOptionPresented = true
            isImageAnnotationSelected = false
            isImageGalleryPresented = false
            isShapeAnnotationSelected = false
        }
    }

    /**
     PDF로 열 수 없는 첨부 파일의 안내 화면을 구성합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - message: 실패 사유 안내 문구입니다.
     - Returns: `some View`
     */
}
