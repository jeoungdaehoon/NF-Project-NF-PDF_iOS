//
//  PortalPDFPreviewView.swift
//  NF
//
//  Created by Codex on 7/30/26.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

/// 자동 저장 스케줄 상태를 SwiftUI 렌더링 상태와 분리해 편집 중 PDFView 재평가를 막습니다.
@MainActor
final class PortalPDFAutosaveController {
    var scheduledTask: Task<Void, Never>?
    var hasPendingSave = false

    func cancelScheduledSave() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}

/// 앱이 백그라운드로 전환되는 동안 마지막 PDF 저장이 중단되지 않도록 실행 시간을 확보합니다.
@MainActor
final class PortalPDFBackgroundSaveController {
    var taskIdentifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard taskIdentifier == .invalid else { return }
        taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "NF PDF edit save") { [weak self] in
            Task { @MainActor in
                self?.end()
            }
        }
    }

    func end() {
        guard taskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskIdentifier)
        taskIdentifier = .invalid
    }
}

/**
 Portal 첨부 PDF를 앱 내부 전체 화면에서 표시하고 간단한 주석 편집을 지원하는 SwiftUI 화면입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalAttachmentPreviewItem``
 */
struct PortalPDFPreviewView: View {
    /// 전체 화면 PDF 보기 닫기 처리를 위한 SwiftUI dismiss 환경 값입니다.
    @Environment(\.dismiss) var dismiss
    /// 웹 포털에서 전달된 현재 네이티브 테마입니다.
    @Environment(\.portalAppTheme) var portalTheme
    /// 편집 박스의 블러 틴트를 시스템 색상과 반대로 적용하기 위한 환경 값입니다.
    @Environment(\.colorScheme) var colorScheme
    /// 최초 전달된 문서와 히스토리 탭에서 선택한 문서를 같은 PDFView에서 전환합니다.
    @State var activeItem: PortalAttachmentPreviewItem
    /// 상단 중앙 문서명을 직접 편집하고 있는지 나타냅니다.
    @State var isEditingPDFDocumentTitle: Bool = false
    /// 편집 중 빈 이름으로 종료한 경우 복원할 직전 문서명입니다.
    @State var pdfDocumentTitleBeforeEditing: String = ""
    /// 상단 문서명 TextField의 키보드 포커스입니다.
    @FocusState var isPDFDocumentTitleFocused: Bool
    /// 타이틀 메뉴에서 여는 문서 폴더 이동 시트 정보입니다.
    @State var pdfDocumentMovePresentation: PortalPDFDocumentMovePresentation?
    /// 전체 문서 복제·이동·삭제 작업의 중복 실행을 막습니다.
    @State var isPDFDocumentOperationInProgress: Bool = false
    /// 현재 편집 문서를 휴지통으로 이동하기 전 확인창 표시 여부입니다.
    @State var isPDFDocumentTrashConfirmationPresented: Bool = false
    /// 타이틀 메뉴 문서 작업 실패 안내입니다.
    @State var pdfDocumentOperationErrorMessage: String?
    /// 휴지통 이동 성공 후 종료 자동 저장이 문서를 다시 활성화하지 않도록 차단합니다.
    @State var suppressPDFPersistenceOnDisappear: Bool = false
    /// 기존 편집 코드가 항상 현재 활성 문서를 참조하도록 제공하는 별칭입니다.
    var item: PortalAttachmentPreviewItem { activeItem }
    /// 현재 문서를 첫 번째로 정렬한 PDF 열람 기록입니다.
    @State var documentHistoryRecords: [PortalPDFDocumentHistoryRecord]
    /// 히스토리 탭 전환 중 중복 입력을 막기 위한 문서 식별자입니다.
    @State var switchingHistoryRecordID: String?
    /// 히스토리의 원격 문서를 다시 열 때만 재사용하는 현재 Portal 인증 세션입니다.
    let historyCookieHeader: String?
    /// 미리보기에서 로컬 저장을 선택했을 때 상위 Route의 설정 상태까지 동기화합니다.
    let onPDFLocalStorageEnabled: () -> Void

    /// PDF 작업영역·타이틀바·문서 탭바에 적용할 네이티브 테마 배경입니다.
    var pdfWorkspaceBackgroundColor: Color {
        portalTheme.pdfWorkspaceBackgroundColor
    }

    init(
        item: PortalAttachmentPreviewItem,
        onPDFLocalStorageEnabled: @escaping () -> Void = {}
    ) {
        var displayItem = item
        displayItem.title = item.title.removingPercentEncoding ?? item.title
        _activeItem = State(initialValue: displayItem)
        _documentHistoryRecords = State(initialValue: PortalPDFDocumentHistoryStore.record(displayItem))
        _switchingHistoryRecordID = State(initialValue: nil)
        self.historyCookieHeader = item.cookieHeader
        self.onPDFLocalStorageEnabled = onPDFLocalStorageEnabled
    }

    /// 시스템 색상 모드와 반대되는 밝기의 블러 배경을 편집 박스에 제공합니다.
    func inverseEditorBlurBackground(cornerRadius: CGFloat) -> some View {
        let tint = colorScheme == .dark
            ? Color.white.opacity(0.24)
            : Color.black.opacity(0.24)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(tint))
            .clipShape(shape)
    }
    /// PDF 선택 시 로컬 파일 저장을 사용할지 여부입니다.
    @AppStorage(AutoLoginPreferenceRepository.pdfLocalStorageEnabledKey) var isPDFLocalStorageEnabled: Bool = false
    /// PDF 원본과 편집 저장본을 관리하는 로컬 캐시 Repository입니다.
    let pdfLocalStorageRepository = PortalPDFLocalStorageRepository()
    /// PDF 다운로드 및 변환 진행 상태입니다.
    @State var state: PortalPDFPreviewLoadState = .loading
    /// 로컬에 없는 PDF를 처음 열 때 표시할 저장 방식 안내입니다.
    @State var initialOpenPrompt: PortalPDFInitialOpenPrompt?
    /// 로컬 저장 다운로드의 실제 수신 진행률입니다.
    @State var localDownloadProgress: Double?
    /// 현재 선택된 PDF 편집 도구입니다.
    @State var selectedTool: PortalPDFMarkupTool = .view
    /// 펜 도구가 활성화된 상태에서 한 번 더 선택했을 때 표시할 펜 상세 편집 박스 표시 여부입니다.
    @State var isPenOptionPresented: Bool = false
    /// 지우개 도구를 한 번 더 선택했을 때 표시할 지우개 크기 편집 박스 표시 여부입니다.
    @State var isEraserOptionPresented: Bool = false
    /// 박스 도구에서 추가할 도형을 선택하는 상세 패널 표시 여부입니다.
    @State var isShapeOptionPresented: Bool = false
    /// 텍스트 도구의 박스 스타일과 명시적 추가 버튼을 표시하는 상세 패널 여부입니다.
    @State var isTextOptionPresented: Bool = false
    /// 박스 도구로 PDF에 추가할 현재 도형 종류입니다.
    @State var selectedShapeType: PortalPDFShapeType = .rectangle
    /// 박스 도구로 추가하거나 선택한 도형에 적용할 선 색상입니다.
    @State var selectedShapeLineColor: Color = .orange
    /// 박스 도구로 추가하거나 선택한 도형에 적용할 배경 색상입니다.
    @State var selectedShapeFillColor: Color = .orange.opacity(0.14)
    /// 텍스트 박스에 적용할 테두리 색상입니다.
    @State var selectedTextBorderColor: Color = .clear
    /// 텍스트 박스에 적용할 배경 색상입니다.
    @State var selectedTextFillColor: Color = .clear
    /// 텍스트 박스에 적용할 문자 색상입니다.
    @State var selectedTextColor: Color = .black
    /// PDF 펜 주석에 적용할 현재 색상입니다.
    @State var selectedPenColor: PortalPDFPenColor = PortalPDFPenColor.defaults[0]
    /// 기본 색상과 사용자가 추가한 색상을 순서대로 보관하는 팔레트입니다.
    @State var penColors: [PortalPDFPenColor] = PortalPDFPenColor.defaults
    /// 사용자가 컬러 편집창에서 변경한 펜 팔레트 색상입니다.
    @State var customizedPenColors: [String: Color] = [:]
    /// 컬러별로 저장된 펜 두께입니다. 컬러 원형 아래 수치와 실제 펜 주석 두께에 함께 사용합니다.
    @State var customizedPenLineWidths: [String: CGFloat] = [:]
    /// 컬러별 압력 반응 강도입니다. 1.0은 기존 압력 반응, 0은 고정 굵기, 2.0은 강화된 반응입니다.
    @State var customizedPenPressureStrengths: [String: CGFloat] = [:]
    /// 컬러별 스트로크 끝 삐침 완화 강도입니다. 100%를 초과하면 최대 200%까지 추가 완화합니다.
    @State var customizedPenStrokeSmoothingStrengths: [String: CGFloat] = [:]
    /// 형광펜에서만 사용하는 컬러별 색상과 두께입니다. 펜슬 설정과 분리해 적용합니다.
    @State var customizedHighlighterColors: [String: Color] = [:]
    @State var customizedHighlighterLineWidths: [String: CGFloat] = [:]
    /// 로컬 펜 팔레트 복원을 한 번만 수행하기 위한 상태입니다.
    @State var didLoadPenPalette: Bool = false
    /// 현재 색상 값 편집기를 표시할 펜 팔레트 항목입니다.
    @State var editingPenColor: PortalPDFPenColor?
    /// 컬러 편집 중 아직 체크하지 않은 임시 컬러 값입니다.
    @State var editingPenColorValue: Color = .blue
    /// 컬러 편집 중 아직 체크하지 않은 임시 펜 두께입니다.
    @State var editingPenLineWidth: CGFloat = 2.4
    /// 컬러 편집 중 조절하는 임시 압력 반응 강도입니다.
    @State var editingPenPressureStrength: CGFloat = 1.0
    /// 컬러 편집 중 조절하는 임시 스트로크 끝 삐침 완화 강도입니다.
    @State var editingPenStrokeSmoothingStrength: CGFloat = 0.5
    /// PDF 펜 주석에 적용할 현재 PDF Page 좌표계 기준 굵기입니다.
    @State var selectedPenLineWidth: CGFloat = 2.4
    /// 펜 계열 도구가 활성화된 동안 컬러 팔레트를 항상 표시할지 여부입니다.
    @AppStorage("nf.pdf.pen.palette.always.visible") var isPenPaletteAlwaysVisible: Bool = false
    /// 펜의 굵기 적용 방식입니다. 선택값은 다음 실행에도 유지합니다.
    @AppStorage("nf.pdf.pen.type") var selectedPenTypeRawValue: String = PortalPDFPenType.fixed.rawValue
    /// 형광펜의 굵기입니다. 기존 형광펜 기본 굵기인 18pt를 최소값으로 유지합니다.
    @AppStorage("nf.pdf.highlighter.line.width") var highlighterLineWidthRaw: Double = 18
    /// 형광펜 시작·끝 부분의 라운드 형태입니다.
    @AppStorage("nf.pdf.highlighter.cap") var selectedHighlighterCapRawValue: String = PortalPDFHighlighterCap.round.rawValue
    /// 지우개가 적용되는 화면 기준 지름입니다.
    @AppStorage("nf.pdf.eraser.size") var eraserSizeRaw: Double = 24
    /// Apple Pencil 이중 탭 시 팬슬과 왕복 전환할 편집 모드입니다.
    @AppStorage("nf.pdf.pencil.doubleTap.tool") var pencilDoubleTapToolRawValue: String = PortalPDFPencilDoubleTapTool.eraser.rawValue
    /// 이미지 추가 도구에서 Photos Picker 표시 여부입니다.
    @State var isImagePickerPresented: Bool = false
    /// Photos Picker에서 사용자가 선택한 이미지 항목입니다.
    @State var selectedImagePickerItem: PhotosPickerItem?
    /// Photos Picker 결과를 새 이미지 삽입 또는 선택 이미지 교체 중 어디에 사용할지 구분합니다.
    @State var imagePickerPurpose: PortalPDFImagePickerPurpose = .insert
    /// PDFView에 1회 삽입 요청으로 전달할 선택 이미지 정보입니다.
    @State var pendingImageAnnotation: PortalPDFPendingImage?
    /// 현재 선택 이미지에 1회 적용할 편집 명령입니다.
    @State var pendingImageEditCommand: PortalPDFImageEditCommand?
    /// PDFView에서 실제 이미지 Annotation 하나가 선택된 상태인지 나타냅니다.
    @State var isImageAnnotationSelected: Bool = false
    /// 선택 이미지를 iOS Quick Look Markup으로 편집하기 위한 임시 파일입니다.
    @State var systemImageEditorItem: PortalPDFSystemImageEditorItem?
    /// 선택 이미지를 사각형 또는 자유선 영역으로 자르기 위한 전용 편집 화면입니다.
    @State var imageCropEditorItem: PortalPDFImageCropEditorItem?
    /// 사진 모드에서 두 번째 사진 도구 탭으로 표시할 현재 사진 Grid 팝업 여부입니다.
    @State var isImageGalleryPresented: Bool = false
    /// 실제 기기 사진첩에서 읽어온 최근 사진 썸네일입니다.
    @State var photoLibraryItems: [PortalPhotoLibraryItem] = []
    /// 사진첩 썸네일을 읽는 중인지 나타냅니다.
    @State var isPhotoLibraryLoading: Bool = false
    /// 사진첩 접근이 제한되었거나 사진을 읽지 못했을 때 표시할 안내 문구입니다.
    @State var photoLibraryMessage: String?
    /// PDFView에서 실제 도형 Annotation 하나가 선택된 상태인지 나타냅니다.
    @State var isShapeAnnotationSelected: Bool = false
    /// PDFView에 1회 삽입 요청으로 전달할 선택 도형 정보입니다.
    @State var pendingShapeAnnotation: PortalPDFPendingShape?
    /// PDFView에 1회 삽입 요청으로 전달할 텍스트 박스 정보입니다.
    @State var pendingTextAnnotation: PortalPDFPendingText?
    /// 기본 편집 박스에서 PDF 편집 실행 취소·다시 실행을 전달하는 1회 명령입니다.
    @State var pendingHistoryCommand: PortalPDFHistoryCommand?
    /// 설정 메뉴에서 현재 페이지 아래에 페이지를 추가·복제하는 1회 명령입니다.
    @State var pendingPageEditCommand: PortalPDFPageEditCommand?
    /// 전체 페이지 목록에서 선택한 페이지로 이동하는 1회 명령입니다.
    @State var pendingPageNavigationCommand: PortalPDFPageNavigationCommand?
    /// 전체 페이지 편집에서 문서 구조가 변경된 뒤 PDFView를 갱신하는 1회 명령입니다.
    @State var pendingPageStructureRefreshCommand: PortalPDFPageStructureRefreshCommand?
    /// PDFView가 현재 표시 중인 페이지 번호입니다.
    @State var currentPDFPageIndex: Int = 0
    /// PDFView의 현재 확대 배율을 하단 페이지 정보 오른쪽에 표시할 정수 퍼센트입니다.
    @State var currentPDFZoomPercentage: Int = 100
    @State var canUndoPDFEdit: Bool = false
    @State var canRedoPDFEdit: Bool = false
    /// 편집된 PDF 저장 진행 상태입니다.
    @State var saveStatus: PortalPDFSaveStatus = .idle
    /// PDF 저장 실패 원인을 사용자에게 안내하기 위한 메시지입니다.
    @State var saveErrorMessage: String?
    /// 로컬 PDF 변경을 짧게 모아 디스크에 기록하는 자동 저장 작업입니다.
    @State var localAutosaveController = PortalPDFAutosaveController()
    /// 앱 정지 전 서버·로컬 PDF의 마지막 편집 저장 시간을 관리합니다.
    @State var backgroundSaveController = PortalPDFBackgroundSaveController()
    /// PDFView 상단 설정 안내 팝업 표시 여부입니다.
    @State var isPDFSettingsPresented: Bool = false
    /// 기본 편집 툴바에서 전환하는 전체화면 모드입니다. 다음 PDF 진입에도 같은 상태를 적용합니다.
    @AppStorage("nf.pdf.editor.fullscreen.mode.enabled") var isPDFEditorFullscreenModeEnabled: Bool = false
    /// PDF 이외의 화면 요소를 숨기는 프레젠테이션 모드 설정입니다.
    @AppStorage("nf.pdf.presentation.mode.enabled") var isPDFPresentationModeEnabled: Bool = false
    /// 프레젠테이션 중 종료·설정 버튼이 있는 상단 바를 일시적으로 표시합니다.
    @State var arePDFPresentationControlsVisible: Bool = false
    /// 프레젠테이션 활성화 직후 세 손가락 종료 UI 호출 방법을 안내하는 토스트입니다.
    @State var isPDFPresentationGestureGuideVisible: Bool = false
    /// 전체 PDF 페이지 썸네일 목록 팝업에 전달할 표시 정보입니다.
    @State var pdfPageNavigatorPresentation: PortalPDFPageNavigatorPresentation?
    /// 페이지 번호 버튼에서 여는 우측 전체 페이지 빠른 목록 표시 여부입니다.
    @State var isPDFPageSideListPresented: Bool = false
    /// 전체 페이지 화면에서 선택한 뒤 화면이 닫히는 시점에 이동할 페이지 번호입니다.
    @State var pendingPDFPageSelection: Int?
    /// 현재 PDF 문서에서 즐겨찾기로 지정한 페이지 번호입니다.
    @State var favoritePDFPageIndexes: Set<Int> = []
    /// PDF 페이지의 이동 방향과 연속/한 장 보기 방식을 다음 진입에도 유지합니다.
    @AppStorage("nf.pdf.display.style") var pdfDisplayStyleRawValue: String = PortalPDFDisplayStyle.verticalContinuous.rawValue
    /// PDF 한 화면에 표시할 페이지 수를 다음 진입에도 유지합니다.
    @AppStorage("nf.pdf.page.layout") var pdfPageLayoutRawValue: String = PortalPDFPageLayout.singlePage.rawValue
    /// 하단 페이지 정보 알약과 전체 페이지 빠른 목록의 좌우 배치입니다.
    @AppStorage("nf.pdf.page.control.position") var pdfPageControlPositionRawValue: String = PortalPDFPageControlPosition.right.rawValue
    /// 로컬 PDF 편집본을 iOS 외부 공유 시트에 전달하는 항목입니다.
    @State var pdfShareItem: PortalPDFShareItem?
    /// 편집 툴 전체 초기화 확인 팝업 표시 여부입니다.
    @State var isPDFEditingResetConfirmationPresented: Bool = false
    /// 하단 편집 알약의 배치 방향을 보관합니다. 기본값은 기존 가로 배치입니다.
    @State var isMarkupToolbarVertical: Bool = false
    /// 사용자가 이동 버튼으로 확정한 편집 알약의 화면상 위치 오프셋입니다.
    @State var markupToolbarOffset: CGSize = .zero
    /// 기본 편집창의 드래그 중 실시간 위치입니다.
    @State var markupToolbarLiveOffset: CGSize = .zero
    /// 화면 경계 계산에 사용하는 PDF 편집 영역 크기입니다.
    @State var markupToolbarContainerSize: CGSize = .zero
    /// 편집 알약의 확정된 외곽 크기입니다. 내부 버튼 크기와 분리해 알약만 자유롭게 조절합니다.
    @State var markupToolbarSize: CGSize = CGSize(width: 278, height: 94)
    /// 크기 조절 핸들을 드래그하는 동안 적용할 임시 가로·세로 이동량입니다.
    @GestureState var markupToolbarResizeTranslation: CGSize = .zero
    /// 크기 조절 제스처가 시작된 시점의 알약 외곽 크기입니다.
    @State var markupToolbarResizeStartSize: CGSize = CGSize(width: 278, height: 94)
    /// 크기 조절 핸들이 활성화된 상태인지 나타냅니다.
    @State var isMarkupToolbarResizing: Bool = false
    /// 펜슬 팔레트 크기 조절 중 임시 이동량입니다.
    @GestureState var penOptionPanelResizeTranslation: CGSize = .zero
    /// 펜슬 팔레트 크기 조절이 시작된 시점의 크기입니다.
    @State var penOptionPanelResizeStartSize: CGSize = .zero
    /// 펜슬 팔레트 크기 조절 중인지 나타냅니다.
    @State var isPenOptionPanelResizing: Bool = false
    /// 펜슬 팔레트에서 마지막으로 확정한 크기입니다.
    @State var penOptionPanelCommittedSize: CGSize = .zero
    /// 마지막 확정 크기가 적용된 팔레트 방향입니다.
    @State var penOptionPanelCommittedIsVertical: Bool = false
    /// 손가락을 놓기 전까지 화면에 유지할 펜슬 팔레트 실시간 크기입니다.
    @State var penOptionPanelLiveSize: CGSize = .zero
    /// 펜슬 팔레트 이동 중인 임시 이동량입니다.
    @GestureState var penOptionPanelMoveTranslation: CGSize = .zero
    /// 펜슬 팔레트 이동 시작 시점의 위치입니다.
    @State var penOptionPanelMoveStartOffset: CGSize = .zero
    /// 펜슬 팔레트 이동 중인지 나타냅니다.
    @State var isPenOptionPanelMoving: Bool = false
    /// 펜슬 팔레트의 잠금 상태입니다.
    @AppStorage("nf.pdf.pen.option.panel.locked") var penOptionPanelLocked: Bool = true
    /// 가로·세로 펜슬 팔레트 크기를 방향별로 로컬에 보관합니다.
    @AppStorage("nf.pdf.pen.option.panel.horizontal.width") var penOptionPanelHorizontalWidthRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.horizontal.height") var penOptionPanelHorizontalHeightRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.vertical.width") var penOptionPanelVerticalWidthRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.vertical.height") var penOptionPanelVerticalHeightRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.horizontal.offset.x") var penOptionPanelHorizontalOffsetXRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.horizontal.offset.y") var penOptionPanelHorizontalOffsetYRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.vertical.offset.x") var penOptionPanelVerticalOffsetXRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.vertical.offset.y") var penOptionPanelVerticalOffsetYRaw: Double = 0
    /// 한 번이라도 잠금이 해제된 팔레트는 기본 편집창과 분리합니다.
    @AppStorage("nf.pdf.pen.option.panel.detached") var penOptionPanelDetached: Bool = false
    @AppStorage("nf.pdf.pen.option.panel.detached.placement") var penOptionPanelDetachedPlacementRaw: String = ""
    /// 팔레트가 기본 편집창에서 분리된 순간의 기준 위치입니다.
    @AppStorage("nf.pdf.pen.option.panel.detached.toolbar.offset.x") var penOptionPanelDetachedToolbarOffsetXRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.detached.toolbar.offset.y") var penOptionPanelDetachedToolbarOffsetYRaw: Double = 0
    /// 분리된 팔레트가 방향 전환 후에도 유지할 크기와 이동 위치입니다.
    @AppStorage("nf.pdf.pen.option.panel.detached.width") var penOptionPanelDetachedWidthRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.detached.height") var penOptionPanelDetachedHeightRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.detached.offset.x") var penOptionPanelDetachedOffsetXRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.detached.offset.y") var penOptionPanelDetachedOffsetYRaw: Double = 0
    @AppStorage("nf.pdf.pen.option.panel.detached.vertical") var penOptionPanelDetachedVerticalRaw: Bool = false
    @AppStorage("nf.pdf.pen.option.panel.detached.scroll.vertical") var penOptionPanelDetachedScrollVerticalRaw: Bool = false

    /// 키보드 조합 중인 텍스트까지 확정하고 앱 정지 전에 마지막 PDF 편집본을 저장합니다.
    @MainActor
    func persistPDFEditsBeforeSuspension() {
        guard !suppressPDFPersistenceOnDisappear else { return }
        localAutosaveController.cancelScheduledSave()
        backgroundSaveController.begin()

        // 활성 UITextView의 marked text가 텍스트 Annotation에 반영되도록 먼저 편집을 종료합니다.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )

        // resignFirstResponder 콜백이 미저장 상태를 갱신한 다음 실제 저장을 수행합니다.
        DispatchQueue.main.async {
            guard localAutosaveController.hasPendingSave else {
                backgroundSaveController.end()
                return
            }
            if item.localFileURL != nil {
                persistPendingLocalPDFEdits()
                backgroundSaveController.end()
                return
            }
            Task { @MainActor in
                await savePDFDocument()
                backgroundSaveController.end()
            }
        }
    }

    /**
     PDF 미리보기 화면 본문입니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Returns: `some View`
     */
    var body: some View {
        NavigationStack {
            previewPresentationLayer
        }
        .background(pdfWorkspaceBackgroundColor.ignoresSafeArea())
        .preferredColorScheme(portalTheme.colorScheme)
    }

    /// 다운로드 상태에 맞는 실제 PDF 화면만 구성합니다.
    @ViewBuilder
    var previewStateContent: some View {
        switch state {
        case .loading:
            loadingView
        case .loaded(let document):
            pdfEditorView(document: document)
        case .failed(let message):
            failedView(message: message)
        }
    }

    /// 공통 화면 크기와 상단 내비게이션 도구를 구성합니다.
    var previewNavigationLayer: some View {
        ZStack {
            VStack(spacing: 0) {
                if !isPDFPresentationModeEnabled {
                    pdfDocumentHistoryTabBar
                }
                previewStateContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isPDFPresentationModeEnabled && isPDFPresentationGestureGuideVisible {
                pdfPresentationGestureGuideToast
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pdfWorkspaceBackgroundColor.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsPDFNavigationControls ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(pdfWorkspaceBackgroundColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(portalTheme.colorScheme, for: .navigationBar)
        .tint(portalTheme.accentColor)
        .toolbar {
            if showsPDFNavigationControls {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        pdfCloseToolbarButton
                    }
                    .sharedBackgroundVisibility(.hidden)

                    ToolbarItem(placement: .principal) {
                        pdfDocumentTitleToolbarContent
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        pdfSettingsToolbarButton
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        pdfCloseToolbarButton
                    }

                    ToolbarItem(placement: .principal) {
                        pdfDocumentTitleToolbarContent
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        pdfSettingsToolbarButton
                    }
                }
            }
        }
    }

    /// PDF 편집 화면을 닫는 아이콘 전용 버튼입니다.
    var pdfCloseToolbarButton: some View {
        Button {
            if isPDFPresentationModeEnabled {
                disablePDFPresentationMode()
            } else {
                persistPendingLocalPDFEdits()
                dismiss()
            }
        } label: {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isPDFPresentationModeEnabled ? "프레젠테이션 모드 종료" : "첨부 미리보기 닫기"
        )
    }

    /// PDF 설정 팝업을 여는 아이콘 전용 버튼입니다.
    var pdfSettingsToolbarButton: some View {
        Button {
            isPDFSettingsPresented = true
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("PDF 설정")
        .popover(
            isPresented: $isPDFSettingsPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            pdfSettingsPopover
        }
    }

    var showsPDFNavigationControls: Bool {
        !isPDFEditorFullscreenModeEnabled &&
            (!isPDFPresentationModeEnabled || arePDFPresentationControlsVisible)
    }

    /// 중앙 문서명과 이름 변경 메뉴를 표시하며, 이름 변경 선택 시 같은 영역을 TextField로 전환합니다.
    @ViewBuilder
    var pdfDocumentTitleToolbarContent: some View {
        if isEditingPDFDocumentTitle {
            TextField(
                "문서 이름",
                text: Binding(
                    get: { activeItem.title },
                    set: { updatePDFDocumentTitle($0) }
                )
            )
            .font(.headline)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.done)
            .autocorrectionDisabled()
            .focused($isPDFDocumentTitleFocused)
            .frame(minWidth: 150, maxWidth: 360)
            .onSubmit {
                finishPDFDocumentTitleEditing()
            }
            .onChange(of: isPDFDocumentTitleFocused) { _, isFocused in
                if !isFocused && isEditingPDFDocumentTitle {
                    finishPDFDocumentTitleEditing()
                }
            }
            .accessibilityLabel("PDF 문서 이름 편집")
        } else {
            HStack(spacing: 6) {
                Text(activeItem.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        beginPDFDocumentTitleEditing()
                    }
                    .accessibilityLabel("문서 이름 \(activeItem.title)")

                Menu {
                    Button {
                        beginPDFDocumentTitleEditing()
                    } label: {
                        Label("이름 변경", systemImage: "pencil")
                    }

                    if item.localFileURL != nil {
                        Button {
                            shareLocalPDFExternally()
                        } label: {
                            Label("외부 공유", systemImage: "square.and.arrow.up")
                        }
                    }

                    Button {
                        toggleCurrentPDFPageFavorite()
                    } label: {
                        Label(
                            isCurrentPDFPageFavorite ? "현 페이지 즐겨찾기 해제" : "현 페이지 즐겨찾기 추가",
                            systemImage: isCurrentPDFPageFavorite ? "star.slash" : "star"
                        )
                    }
                    .disabled(loadedDocument?.pageCount == 0)

                    Divider()

                    Button {
                        duplicateCurrentPDFDocument()
                    } label: {
                        Label("문서 복제", systemImage: "doc.on.doc")
                    }
                    .disabled(loadedDocument == nil || isPDFDocumentOperationInProgress)

                    if activeItem.localDocumentID != nil {
                        Button {
                            presentPDFDocumentMoveSheet()
                        } label: {
                            Label("파일 이동", systemImage: "folder")
                        }
                        .disabled(isPDFDocumentOperationInProgress)

                        Divider()

                        Button(role: .destructive) {
                            isPDFDocumentTrashConfirmationPresented = true
                        } label: {
                            Label("문서를 휴지통으로 이동 후 종료", systemImage: "trash")
                        }
                        .disabled(isPDFDocumentOperationInProgress)
                    }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.subheadline)
                        .scaleEffect(0.5)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("문서 이름 메뉴 펼치기")
            }
            .frame(minWidth: 120, maxWidth: 360)
        }
    }

    /// 프레젠테이션 종료 UI를 다시 불러오는 방법을 화면 중앙에 잠시 안내합니다.
    var pdfPresentationGestureGuideToast: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fingers.spread.fill")
                .font(.title2)
                .foregroundStyle(portalTheme.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("프레젠테이션 모드")
                    .font(.subheadline.weight(.semibold))
                Text("손가락 3개로 위 또는 아래로 쓸어\n종료 UI를 표시할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(portalTheme.foregroundColor)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 7)
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("프레젠테이션 모드. 손가락 3개로 위 또는 아래로 쓸어 종료 UI를 표시할 수 있습니다.")
    }

    /// 지금까지 열어본 문서를 가로 탭으로 표시하며 활성 문서는 항상 가장 왼쪽에 둡니다.
    var pdfDocumentHistoryTabBar: some View {
        HStack(spacing: 0) {
            if isPDFEditorFullscreenModeEnabled {
                pdfFullscreenTabBarCloseButton
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(documentHistoryRecords) { record in
                        let isActive = record.id == currentDocumentHistoryID
                        Button {
                            guard !isActive, switchingHistoryRecordID == nil else { return }
                            Task { @MainActor in
                                await switchToHistoryDocument(record)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                if switchingHistoryRecordID == record.id {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: isActive ? "doc.text.fill" : "doc.text")
                                        .font(.caption)
                                }
                                Text(isActive ? activeItem.title : record.title)
                                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(isActive ? portalTheme.foregroundColor : portalTheme.mutedColor)
                            .padding(.horizontal, 14)
                            .frame(minWidth: 112, maxWidth: 220, minHeight: 42)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(isActive ? portalTheme.accentColor : Color.clear)
                                    .frame(height: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(switchingHistoryRecordID != nil && switchingHistoryRecordID != record.id)
                        .accessibilityLabel("\(isActive ? activeItem.title : record.title) 문서")
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if isPDFEditorFullscreenModeEnabled {
                pdfFullscreenTabBarSettingsButton
            }
        }
        .frame(height: 42)
        .scrollIndicators(.hidden)
        .background(pdfWorkspaceBackgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(portalTheme.borderColor)
                .frame(height: 1)
        }
    }

    /// 전체화면 중에도 문서 종료 동작을 유지하는 탭바의 가장 왼쪽 버튼입니다.
    var pdfFullscreenTabBarCloseButton: some View {
        Button {
            persistPendingLocalPDFEdits()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("첨부 미리보기 닫기")
    }

    /// 전체화면 중에도 PDF 설정을 여는 탭바의 가장 오른쪽 버튼입니다.
    var pdfFullscreenTabBarSettingsButton: some View {
        Button {
            isPDFSettingsPresented = true
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("PDF 설정")
        .popover(
            isPresented: $isPDFSettingsPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            pdfSettingsPopover
        }
    }

    var currentDocumentHistoryID: String {
        item.historyIdentifier
    }

    /// 이름 변경 메뉴 선택 시 기존 PDF 입력을 종료하고 중앙 제목 영역에 키보드 포커스를 줍니다.
    func beginPDFDocumentTitleEditing() {
        pdfDocumentTitleBeforeEditing = activeItem.title
        isEditingPDFDocumentTitle = true
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        Task { @MainActor in
            await Task.yield()
            isPDFDocumentTitleFocused = true
        }
    }

    /// TextField 입력값을 타이틀과 열람 기록에 즉시 반영하고 로컬 문서명도 함께 갱신합니다.
    func updatePDFDocumentTitle(_ title: String) {
        activeItem.title = title
        guard let persistedTitle = normalizedPDFDocumentTitle(title) else { return }
        persistPDFDocumentTitle(persistedTitle, reportsError: false)
    }

    /// 빈 이름은 직전 값으로 복원하고 유효한 이름은 PDF 확장자를 보정해 편집을 확정합니다.
    func finishPDFDocumentTitleEditing() {
        guard isEditingPDFDocumentTitle else { return }
        isEditingPDFDocumentTitle = false
        let finalTitle = normalizedPDFDocumentTitle(activeItem.title)
            ?? normalizedPDFDocumentTitle(pdfDocumentTitleBeforeEditing)
            ?? "PDF 문서.pdf"
        activeItem.title = finalTitle
        persistPDFDocumentTitle(finalTitle, reportsError: true)
        isPDFDocumentTitleFocused = false
    }

    /// 줄바꿈과 가장자리 공백을 제거하고 로컬 PDF 문서는 `.pdf` 확장자를 유지합니다.
    func normalizedPDFDocumentTitle(_ title: String) -> String? {
        let normalizedTitle = title
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return nil }
        guard activeItem.localDocumentID != nil,
              !normalizedTitle.lowercased().hasSuffix(".pdf") else {
            return normalizedTitle
        }
        return "\(normalizedTitle).pdf"
    }

    /// 변경 이름을 문서 히스토리에 저장하고 로컬 문서인 경우 라이브러리 메타데이터까지 갱신합니다.
    func persistPDFDocumentTitle(_ title: String, reportsError: Bool) {
        documentHistoryRecords = PortalPDFDocumentHistoryStore.rename(
            id: currentDocumentHistoryID,
            title: title
        )
        guard let localDocumentID = activeItem.localDocumentID else { return }
        do {
            try pdfLocalStorageRepository.rename(documentID: localDocumentID, fileName: title)
        } catch {
            if reportsError {
                saveErrorMessage = "PDF 문서 이름을 변경하지 못했습니다."
            }
        }
    }

    /// 현재 편집 상태를 포함한 PDF 전체를 새 로컬 문서로 복제하고 복제본 편집 화면으로 전환합니다.
    func duplicateCurrentPDFDocument() {
        guard !isPDFDocumentOperationInProgress else { return }
        isPDFDocumentOperationInProgress = true
        Task { @MainActor in
            defer { isPDFDocumentOperationInProgress = false }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
            await Task.yield()
            localAutosaveController.cancelScheduledSave()
            persistPendingLocalPDFEdits()
            guard let document = loadedDocument,
                  let data = document.portalBaseDataRepresentation() else {
                pdfDocumentOperationErrorMessage = "현재 PDF 편집본을 복제할 수 없습니다."
                return
            }

            let documents = pdfLocalStorageRepository.documents()
            let currentLocalDocument = activeItem.localDocumentID.flatMap { documentID in
                documents.first { $0.id == documentID }
            }
            let duplicateTitle = nextDuplicatedPDFDocumentTitle(
                from: activeItem.title,
                existingDocuments: documents
            )
            do {
                let duplicatedDocument = try pdfLocalStorageRepository.createDocument(
                    data: data,
                    fileName: duplicateTitle,
                    sourceURL: activeItem.url,
                    folderID: currentLocalDocument?.folderID
                )
                try PortalPDFPageEditRepository().copy(
                    from: activeItem.historyIdentifier,
                    to: duplicatedDocument.id
                )
                saveMarkupToolbarState()
                let targetItem = PortalAttachmentPreviewItem(localDocument: duplicatedDocument)
                resetPDFSessionForDocumentSwitch()
                activeItem = targetItem
                documentHistoryRecords = PortalPDFDocumentHistoryStore.record(targetItem)
            } catch {
                pdfDocumentOperationErrorMessage = "PDF 문서 복제본을 만들지 못했습니다."
            }
        }
    }

    /// 현재 제목 끝에 `+1`부터 사용 가능한 번호를 붙여 중복되지 않는 복제 문서명을 만듭니다.
    func nextDuplicatedPDFDocumentTitle(
        from title: String,
        existingDocuments: [PortalLocalPDFDocument]
    ) -> String {
        let titleNSString = title as NSString
        let baseName = titleNSString.pathExtension.lowercased() == "pdf"
            ? titleNSString.deletingPathExtension
            : title
        let existingNames = Set(existingDocuments.map { $0.fileName.lowercased() })
        var copyNumber = 1
        while existingNames.contains("\(baseName) +\(copyNumber).pdf".lowercased()) {
            copyNumber += 1
        }
        return "\(baseName) +\(copyNumber).pdf"
    }

    /// 현재 로컬 문서와 현재 폴더 정보를 전달해 이동 가능한 폴더 선택 시트를 엽니다.
    func presentPDFDocumentMoveSheet() {
        guard let localDocumentID = activeItem.localDocumentID else { return }
        let currentDocument = pdfLocalStorageRepository.documents().first { $0.id == localDocumentID }
        guard let currentDocument else {
            pdfDocumentOperationErrorMessage = "이동할 로컬 PDF 문서 정보를 찾지 못했습니다."
            return
        }
        pdfDocumentMovePresentation = PortalPDFDocumentMovePresentation(
            documentID: localDocumentID,
            documentTitle: activeItem.title,
            currentFolderID: currentDocument.folderID
        )
    }

    /// 현재 편집 내용을 저장한 뒤 로컬 문서를 휴지통으로 이동하고 PDF 화면을 종료합니다.
    func moveCurrentPDFDocumentToTrashAndDismiss() {
        guard !isPDFDocumentOperationInProgress,
              let localDocumentID = activeItem.localDocumentID else { return }
        isPDFDocumentOperationInProgress = true
        Task { @MainActor in
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
            await Task.yield()
            localAutosaveController.cancelScheduledSave()
            persistPendingLocalPDFEdits()
            do {
                try pdfLocalStorageRepository.moveToTrash(documentID: localDocumentID)
                suppressPDFPersistenceOnDisappear = true
                localAutosaveController.hasPendingSave = false
                documentHistoryRecords = PortalPDFDocumentHistoryStore.remove(
                    id: currentDocumentHistoryID
                )
                isPDFDocumentOperationInProgress = false
                dismiss()
            } catch {
                isPDFDocumentOperationInProgress = false
                pdfDocumentOperationErrorMessage = "현재 PDF 문서를 휴지통으로 이동하지 못했습니다."
            }
        }
    }

    /// 확인창과 초기 열기 안내를 화면 구성에서 분리합니다.
    var previewAlertLayer: some View {
        previewNavigationLayer
            .alert("편집 툴 초기화", isPresented: $isPDFEditingResetConfirmationPresented) {
                Button("취소", role: .cancel) {}
                Button("예", role: .destructive) {
                    resetPDFEditingState()
                    isPDFSettingsPresented = false
                }
            } message: {
                Text("저장된 편집 툴의 위치, 크기, 방향, 팔레트, 컬러와 기타 설정을 모두 삭제하고 최초 진입 기본값으로 되돌립니다. PDF에 이미 저장된 주석은 삭제되지 않습니다.")
            }
            .alert(item: $initialOpenPrompt) { prompt in
                initialOpenAlert(for: prompt)
            }
            .alert("문서를 휴지통으로 이동할까요?", isPresented: $isPDFDocumentTrashConfirmationPresented) {
                Button("취소", role: .cancel) {}
                Button("이동 후 종료", role: .destructive) {
                    moveCurrentPDFDocumentToTrashAndDismiss()
                }
            } message: {
                Text("현재 편집 내용을 저장한 뒤 문서를 휴지통으로 이동하고 PDF 편집 화면을 종료합니다.")
            }
    }

    /// PDF 및 툴바 상태의 수명주기 이벤트를 분리해 컴파일러 타입 추론 부담을 줄입니다.
    var previewLifecycleLayer: some View {
        previewAlertLayer
            .task(id: item.id) {
                documentHistoryRecords = PortalPDFDocumentHistoryStore.record(item)
                restoreMarkupToolbarState()
                restoreFavoritePDFPages()
                await preparePDFDocumentOpening()
                updateFavoritePDFPages(favoritePDFPageIndexes)
            }
            .task(id: isImageGalleryPresented) {
                guard isImageGalleryPresented else { return }
                await loadPhotoLibraryItems()
            }
            .task {
                loadPenPalette()
                migrateDetachedPenOptionPanelStateIfNeeded()
            }
            .task(id: isPDFPresentationModeEnabled) {
                guard isPDFPresentationModeEnabled else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isPDFPresentationGestureGuideVisible = false
                    }
                    return
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    isPDFPresentationGestureGuideVisible = true
                }
                do {
                    try await Task.sleep(for: .seconds(3.5))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    isPDFPresentationGestureGuideVisible = false
                }
            }
            .onChange(of: selectedTool) { _, _ in
                enforceAlwaysVisiblePenPaletteIfNeeded()
                saveMarkupToolbarState()
            }
            .onChange(of: isMarkupToolbarVertical) { _, _ in
                saveMarkupToolbarState()
            }
            .onChange(of: markupToolbarOffset) { _, _ in
                saveMarkupToolbarState()
            }
            .onChange(of: markupToolbarSize) { _, _ in
                saveMarkupToolbarState()
            }
            .onChange(of: isPenOptionPresented) { _, isPresented in
                if isPenPaletteAlwaysVisible,
                   selectedTool.isInkTool,
                   !isPresented {
                    isPenOptionPresented = true
                    return
                }
                saveMarkupToolbarState()
            }
            .onChange(of: isShapeOptionPresented) { _, _ in
                saveMarkupToolbarState()
            }
            .onChange(of: selectedShapeLineColor) { _, _ in
                saveMarkupToolbarState()
            }
            .onChange(of: selectedShapeFillColor) { _, _ in
                saveMarkupToolbarState()
            }
            .onChange(of: isPDFPresentationModeEnabled) { _, isEnabled in
                updatePDFPresentationMode(isEnabled: isEnabled)
            }
            .onDisappear {
                localAutosaveController.cancelScheduledSave()
                if !suppressPDFPersistenceOnDisappear {
                    persistPendingLocalPDFEdits()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                persistPDFEditsBeforeSuspension()
            }
    }

    /// 현재 편집본을 보존한 뒤 선택한 히스토리 문서를 같은 PDFView 화면에서 엽니다.
    @MainActor
    func switchToHistoryDocument(_ record: PortalPDFDocumentHistoryRecord) async {
        guard record.id != currentDocumentHistoryID,
              switchingHistoryRecordID == nil else { return }
        switchingHistoryRecordID = record.id
        defer { switchingHistoryRecordID = nil }

        localAutosaveController.cancelScheduledSave()
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        await Task.yield()

        guard await persistCurrentPDFBeforeHistorySwitch() else { return }
        saveMarkupToolbarState()

        let targetItem = PortalAttachmentPreviewItem(
            historyRecord: record,
            cookieHeader: historyCookieHeader
        )
        resetPDFSessionForDocumentSwitch()
        activeItem = targetItem
        documentHistoryRecords = PortalPDFDocumentHistoryStore.record(targetItem)
    }

    /// 문서 전환으로 편집 내용이 유실되지 않도록 현재 문서 저장 가능 방식에 맞춰 먼저 기록합니다.
    @MainActor
    func persistCurrentPDFBeforeHistorySwitch() async -> Bool {
        guard localAutosaveController.hasPendingSave else { return true }

        if item.localFileURL != nil {
            persistPendingLocalPDFEdits()
            return !localAutosaveController.hasPendingSave
        }
        if canSavePDFDocument {
            await savePDFDocument()
            return saveStatus != .failed
        }
        if shouldUseLocalPDFFile,
           let document = loadedDocument,
           let data = document.portalBaseDataRepresentation() {
            do {
                try pdfLocalStorageRepository.save(data, for: item)
                localAutosaveController.hasPendingSave = false
                return true
            } catch {
                saveStatus = .failed
                saveErrorMessage = "현재 PDF 편집본을 저장하지 못해 다른 문서로 이동하지 않았습니다."
                return false
            }
        }

        saveStatus = .failed
        saveErrorMessage = "현재 PDF는 편집 내용을 저장할 수 없어 다른 문서로 이동하지 않았습니다."
        return false
    }

    /// 이전 PDFDocument에 연결된 일회성 명령과 선택 상태를 새 문서에 전달하지 않도록 초기화합니다.
    @MainActor
    func resetPDFSessionForDocumentSwitch() {
        state = .loading
        initialOpenPrompt = nil
        localDownloadProgress = nil
        selectedTool = .view
        isPenOptionPresented = false
        isEraserOptionPresented = false
        isShapeOptionPresented = false
        isTextOptionPresented = false
        isImagePickerPresented = false
        selectedImagePickerItem = nil
        pendingImageAnnotation = nil
        pendingImageEditCommand = nil
        isImageAnnotationSelected = false
        isImageGalleryPresented = false
        systemImageEditorItem = nil
        imageCropEditorItem = nil
        isShapeAnnotationSelected = false
        pendingShapeAnnotation = nil
        pendingTextAnnotation = nil
        pendingHistoryCommand = nil
        pendingPageEditCommand = nil
        pendingPageNavigationCommand = nil
        pendingPageStructureRefreshCommand = nil
        currentPDFPageIndex = 0
        canUndoPDFEdit = false
        canRedoPDFEdit = false
        favoritePDFPageIndexes = []
        pdfPageNavigatorPresentation = nil
        pendingPDFPageSelection = nil
        isPDFSettingsPresented = false
        isEditingPDFDocumentTitle = false
        isPDFDocumentTitleFocused = false
        arePDFPresentationControlsVisible = false
        suppressPDFPersistenceOnDisappear = false
        saveStatus = .idle
        saveErrorMessage = nil
        localAutosaveController.hasPendingSave = false
        isMarkupToolbarVertical = false
        markupToolbarOffset = .zero
        markupToolbarLiveOffset = .zero
        markupToolbarSize = CGSize(width: 278, height: 94)
    }

    /// 사진 선택, 시스템 이미지 편집 및 외부 공유 화면을 구성합니다.
    var previewPresentationLayer: some View {
        previewLifecycleLayer
            .photosPicker(isPresented: $isImagePickerPresented, selection: $selectedImagePickerItem, matching: .images)
            .onChange(of: selectedImagePickerItem) { _, newItem in
                Task {
                    await loadSelectedImageAnnotation(newItem)
                }
            }
            .fullScreenCover(item: $systemImageEditorItem) { editorItem in
                PortalPDFSystemImageEditor(
                    fileURL: editorItem.fileURL,
                    onEdited: { editedImage in
                        pendingImageEditCommand = PortalPDFImageEditCommand(operation: .replace(editedImage))
                        systemImageEditorItem = nil
                    },
                    onCancel: {
                        systemImageEditorItem = nil
                    }
                )
                .onDisappear {
                    try? FileManager.default.removeItem(at: editorItem.fileURL)
                }
            }
            .fullScreenCover(item: $imageCropEditorItem) { editorItem in
                PortalPDFImageCropEditorView(item: editorItem) { result in
                    pendingImageEditCommand = PortalPDFImageEditCommand(
                        operation: .applyCrop(result.image, keepsOriginal: result.keepsOriginal)
                    )
                    imageCropEditorItem = nil
                }
            }
            .sheet(item: $pdfShareItem) { shareItem in
                PortalPDFActivityView(fileURL: shareItem.fileURL)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $pdfDocumentMovePresentation) { presentation in
                PortalPDFDocumentMoveSheet(presentation: presentation)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(
                item: $pdfPageNavigatorPresentation,
                onDismiss: applyPendingPDFPageSelection
            ) { presentation in
                PortalPDFPageNavigatorView(
                    document: presentation.document,
                    currentPageIndex: presentation.currentPageIndex,
                    favoritePageIndexes: presentation.favoritePageIndexes,
                    onSelectPage: { pageIndex in
                        pendingPDFPageSelection = pageIndex
                    },
                    onDocumentStructureChanged: { selectedPageIndex in
                        currentPDFPageIndex = selectedPageIndex
                        pendingPageStructureRefreshCommand = PortalPDFPageStructureRefreshCommand(
                            selectedPageIndex: selectedPageIndex
                        )
                    },
                    onFavoritePageIndexesChanged: { pageIndexes in
                        updateFavoritePDFPages(pageIndexes)
                    }
                )
            }
            .alert("PDF 저장 실패", isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { saveErrorMessage = nil }
                }
            )) {
                Button("확인", role: .cancel) {
                    saveErrorMessage = nil
                }
            } message: {
                Text(saveErrorMessage ?? "PDF 편집본을 저장하지 못했습니다.")
            }
            .alert("문서 작업 실패", isPresented: Binding(
                get: { pdfDocumentOperationErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { pdfDocumentOperationErrorMessage = nil }
                }
            )) {
                Button("확인", role: .cancel) {
                    pdfDocumentOperationErrorMessage = nil
                }
            } message: {
                Text(pdfDocumentOperationErrorMessage ?? "문서 작업을 완료하지 못했습니다.")
            }
    }

    /// iOS 파일 앱의 컨텍스트 메뉴 비율을 기준으로 설정 행의 아이콘·문구 정렬을 통일합니다.
    func pdfSettingsRow(
        _ title: String,
        systemImage: String,
        subtitle: String? = nil,
        foregroundColor: Color? = nil
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 26, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(foregroundColor ?? portalTheme.foregroundColor)
        .frame(maxWidth: .infinity, minHeight: subtitle == nil ? 44 : 50, alignment: .leading)
        .contentShape(Rectangle())
    }

    var pdfSettingsPopover: some View {
        ScrollView(.vertical, showsIndicators: false) {
            pdfSettingsPopoverContent
        }
        .frame(width: 300, height: 520)
        .scrollBounceBehavior(.basedOnSize)
        .presentationCompactAdaptation(.popover)
    }

    var pdfSettingsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isPDFPresentationModeEnabled) {
                pdfSettingsRow(
                    "프레젠테이션 모드",
                    systemImage: "rectangle.on.rectangle",
                    subtitle: isPDFPresentationModeEnabled ? "페이지 번호만 표시" : "편집 화면 전체 표시"
                )
            }
            .tint(.accentColor)

            Divider()

            Button {
                prepareFavoritePDFPagesForInsertion(duplicatesCurrentPage: false)
                pendingPageEditCommand = PortalPDFPageEditCommand(operation: .addBlankPage)
                isPDFSettingsPresented = false
            } label: {
                pdfSettingsRow("페이지 추가", systemImage: "doc.badge.plus")
            }
            Button {
                prepareFavoritePDFPagesForInsertion(duplicatesCurrentPage: true)
                pendingPageEditCommand = PortalPDFPageEditCommand(operation: .duplicateCurrentPage)
                isPDFSettingsPresented = false
            } label: {
                pdfSettingsRow("현 페이지 복제", systemImage: "doc.on.doc")
            }

            Button {
                guard let document = loadedDocument else { return }
                let presentation = PortalPDFPageNavigatorPresentation(
                    document: document,
                    currentPageIndex: currentPDFPageIndex,
                    favoritePageIndexes: favoritePDFPageIndexes
                )
                isPDFSettingsPresented = false
                Task { @MainActor in
                    await Task.yield()
                    pdfPageNavigatorPresentation = presentation
                }
            } label: {
                pdfSettingsRow(
                    "전체 페이지 보기",
                    systemImage: "rectangle.grid.2x2",
                    subtitle: "\(loadedDocument?.pageCount ?? 0)개 페이지"
                )
            }
            .disabled(loadedDocument?.pageCount == 0)

            Button {
                toggleCurrentPDFPageFavorite()
            } label: {
                pdfSettingsRow(
                    isCurrentPDFPageFavorite ? "현 페이지 즐겨찾기 해제" : "현 페이지 즐겨찾기 추가",
                    systemImage: isCurrentPDFPageFavorite ? "star.fill" : "star",
                    subtitle: "즐겨찾기 \(favoritePDFPageIndexes.count)개"
                )
            }
            .disabled(loadedDocument?.pageCount == 0)

            Divider()

            Menu {
                ForEach(PortalPDFDisplayStyle.allCases) { style in
                    Button {
                        pdfDisplayStyleRawValue = style.rawValue
                    } label: {
                        if style == pdfDisplayStyle {
                            Label(style.title, systemImage: "checkmark")
                        } else {
                            Text(style.title)
                        }
                    }
                }
            } label: {
                pdfSettingsRow(
                    "PDF 파일 보는 스타일",
                    systemImage: "rectangle.on.rectangle.angled",
                    subtitle: pdfDisplayStyle.title
                )
            }

            Menu {
                ForEach(PortalPDFPageLayout.allCases) { layout in
                    Button {
                        pdfPageLayoutRawValue = layout.rawValue
                    } label: {
                        if layout == pdfPageLayout {
                            Label(layout.title, systemImage: "checkmark")
                        } else {
                            Label(layout.title, systemImage: layout.systemImageName)
                        }
                    }
                }
            } label: {
                pdfSettingsRow(
                    "한 화면 보기 타입",
                    systemImage: pdfPageLayout.systemImageName,
                    subtitle: pdfPageLayout.title
                )
            }

            Menu {
                ForEach(PortalPDFPageControlPosition.allCases) { position in
                    Button {
                        withAnimation(pdfPageSideListSpringAnimation) {
                            isPDFPageSideListPresented = false
                            pdfPageControlPositionRawValue = position.rawValue
                        }
                    } label: {
                        if position == pdfPageControlPosition {
                            Label(position.title, systemImage: "checkmark")
                        } else {
                            Label(position.title, systemImage: position.systemImageName)
                        }
                    }
                }
            } label: {
                pdfSettingsRow(
                    "페이지 번호·전체보기 위치",
                    systemImage: pdfPageControlPosition.systemImageName,
                    subtitle: pdfPageControlPosition.title
                )
            }

            Toggle(isOn: $isPenPaletteAlwaysVisible) {
                pdfSettingsRow(
                    "펜슬 팔레트 상세 활성화",
                    systemImage: "paintpalette",
                    subtitle: isPenPaletteAlwaysVisible ? "펜슬 사용 중 항상 표시" : "펜슬 버튼으로 열기·닫기"
                )
            }
            .tint(.accentColor)
            .onChange(of: isPenPaletteAlwaysVisible) { _, isEnabled in
                if isEnabled {
                    enforceAlwaysVisiblePenPaletteIfNeeded()
                }
            }

            if UIDevice.current.userInterfaceIdiom == .pad {
                Menu {
                    ForEach(PortalPDFPencilDoubleTapTool.allCases) { tool in
                        Button {
                            pencilDoubleTapToolRawValue = tool.rawValue
                        } label: {
                            if tool == pencilDoubleTapTool {
                                Label(tool.title, systemImage: "checkmark")
                            } else {
                                Label(tool.title, systemImage: tool.systemImageName)
                            }
                        }
                    }
                } label: {
                    pdfSettingsRow(
                        "팬슬 더블 터치 편집 모드",
                        systemImage: "applepencil.and.scribble",
                        subtitle: pencilDoubleTapTool.title
                    )
                }

                Text("팬슬 모드에서 이중 탭하면 선택한 편집 모드로 이동하고, 다시 이중 탭하면 팬슬로 돌아옵니다.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
                    .padding(.bottom, 4)
            }

            Divider()

            if item.localFileURL != nil {
                Button {
                    shareLocalPDFExternally()
                } label: {
                    pdfSettingsRow("외부 공유", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    Task {
                        await savePDFDocument()
                        isPDFSettingsPresented = false
                    }
                } label: {
                    pdfSettingsRow("편집 내용 저장", systemImage: saveStatus.systemImageName)
                }
                .disabled(!canSavePDFDocument || saveStatus == .saving)

                Button {
                    UIApplication.shared.open(item.url)
                    isPDFSettingsPresented = false
                } label: {
                    pdfSettingsRow("Safari에서 열기", systemImage: "safari")
                }
            }

            Divider()

            Button(role: .destructive) {
                isPDFSettingsPresented = false
                Task { @MainActor in
                    await Task.yield()
                    isPDFEditingResetConfirmationPresented = true
                }
            } label: {
                pdfSettingsRow(
                    "편집 툴 전체 초기화",
                    systemImage: "arrow.counterclockwise",
                    foregroundColor: .red
                )
            }

            Text("위치, 크기, 방향, 팔레트와 저장된 편집 설정을 최초 기본값으로 되돌립니다.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.leading, 40)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    var pdfDisplayStyle: PortalPDFDisplayStyle {
        PortalPDFDisplayStyle(rawValue: pdfDisplayStyleRawValue) ?? .verticalContinuous
    }

    var pdfPageLayout: PortalPDFPageLayout {
        PortalPDFPageLayout(rawValue: pdfPageLayoutRawValue) ?? .singlePage
    }

    var pdfPageControlPosition: PortalPDFPageControlPosition {
        PortalPDFPageControlPosition(rawValue: pdfPageControlPositionRawValue) ?? .right
    }

    var pencilDoubleTapTool: PortalPDFPencilDoubleTapTool {
        PortalPDFPencilDoubleTapTool(rawValue: pencilDoubleTapToolRawValue) ?? .eraser
    }

    var isCurrentPDFPageFavorite: Bool {
        favoritePDFPageIndexes.contains(currentPDFPageIndex)
    }

    /// 현재 페이지의 즐겨찾기 상태를 전환해 문서별 설정으로 즉시 저장합니다.
    func toggleCurrentPDFPageFavorite() {
        guard let document = loadedDocument,
              document.pageCount > 0,
              document.page(at: currentPDFPageIndex) != nil else { return }
        var updatedIndexes = favoritePDFPageIndexes
        if updatedIndexes.contains(currentPDFPageIndex) {
            updatedIndexes.remove(currentPDFPageIndex)
        } else {
            updatedIndexes.insert(currentPDFPageIndex)
        }
        updateFavoritePDFPages(updatedIndexes)
    }

    /// 문서별로 저장된 즐겨찾기 페이지를 현재 화면 상태로 복원합니다.
    func restoreFavoritePDFPages() {
        favoritePDFPageIndexes = PortalPDFFavoritePageStore.load(
            for: pdfViewportPersistenceIdentifier
        )
    }

    /// 유효한 페이지 번호만 유지하고 즐겨찾기 상태를 저장합니다.
    func updateFavoritePDFPages(_ pageIndexes: Set<Int>) {
        let pageCount = loadedDocument?.pageCount ?? Int.max
        let validIndexes = Set(pageIndexes.filter { $0 >= 0 && $0 < pageCount })
        favoritePDFPageIndexes = validIndexes
        PortalPDFFavoritePageStore.save(
            validIndexes,
            for: pdfViewportPersistenceIdentifier
        )
    }

    /// 현재 페이지 다음에 페이지가 삽입될 때 기존 즐겨찾기 번호를 새 문서 순서에 맞춥니다.
    func prepareFavoritePDFPagesForInsertion(duplicatesCurrentPage: Bool) {
        let insertionIndex = currentPDFPageIndex + 1
        var updatedIndexes = Set(favoritePDFPageIndexes.map { pageIndex in
            pageIndex >= insertionIndex ? pageIndex + 1 : pageIndex
        })
        if duplicatesCurrentPage && favoritePDFPageIndexes.contains(currentPDFPageIndex) {
            updatedIndexes.insert(insertionIndex)
        }
        // 실제 PDF 삽입 명령보다 먼저 호출되므로 현재 pageCount로 잘라내지 않습니다.
        favoritePDFPageIndexes = updatedIndexes
        PortalPDFFavoritePageStore.save(
            updatedIndexes,
            for: pdfViewportPersistenceIdentifier
        )
    }

    /// 전체 페이지 화면이 닫힌 뒤 PDFView가 다시 보이는 시점에 선택 페이지로 이동합니다.
    func applyPendingPDFPageSelection() {
        guard let pageIndex = pendingPDFPageSelection else { return }
        pendingPDFPageSelection = nil
        currentPDFPageIndex = pageIndex
        pendingPageNavigationCommand = PortalPDFPageNavigationCommand(pageIndex: pageIndex)
    }

    /// Apple Pencil 이중 탭을 팬슬과 사용자가 지정한 편집 모드 사이의 왕복 전환으로 처리합니다.
    func handlePencilDoubleTap() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let configuredTool = pencilDoubleTapTool.markupTool
        if selectedTool == .pen {
            selectMarkupTool(configuredTool)
        } else if selectedTool == configuredTool {
            selectMarkupTool(.pen)
        }
    }

    /// 프레젠테이션 설정 변경 시 열려 있던 보조 UI를 닫고 상단 바 표시 상태를 초기화합니다.
    func updatePDFPresentationMode(isEnabled: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            arePDFPresentationControlsVisible = false
            isPDFSettingsPresented = false
            if isEnabled {
                isPDFPageSideListPresented = false
                pdfPageNavigatorPresentation = nil
            }
        }
        if isEnabled {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }

    /// 마지막 페이지 도달 또는 세 손가락 스와이프 시 종료·설정 버튼을 다시 표시합니다.
    func revealPDFPresentationControls() {
        guard isPDFPresentationModeEnabled,
              !arePDFPresentationControlsVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            arePDFPresentationControlsVisible = true
        }
    }

    /// 프레젠테이션 상단 X 버튼에서 문서를 닫지 않고 일반 PDF 편집 화면으로 복귀합니다.
    func disablePDFPresentationMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isPDFPresentationModeEnabled = false
            arePDFPresentationControlsVisible = false
        }
    }

    /// 마지막 편집을 로컬 파일에 먼저 기록한 뒤 iOS 시스템 공유 시트를 표시합니다.
    @MainActor
    func shareLocalPDFExternally() {
        guard item.localFileURL != nil,
              let document = loadedDocument,
              let exportData = document.portalFlattenedDataRepresentation()
                ?? document.dataRepresentation() else { return }
        localAutosaveController.cancelScheduledSave()
        persistPendingLocalPDFEdits()
        isPDFSettingsPresented = false
        do {
            let exportURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("pdf")
            try exportData.write(to: exportURL, options: [.atomic])
            DispatchQueue.main.async {
                pdfShareItem = PortalPDFShareItem(fileURL: exportURL)
            }
        } catch {
            saveErrorMessage = "PDF 공유 파일을 만들지 못했습니다."
        }
    }

    /**
     PDF 문서와 하단 편집 도구를 함께 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - document: PDFKit에서 표시할 PDF 문서입니다.
     - Returns: `some View`
     */
    func pdfEditorView(document: PDFDocument) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                PortalPDFKitView(
                    document: document,
                    displayStyle: pdfDisplayStyle,
                    pageLayout: pdfPageLayout,
                    viewerBackgroundColor: pdfWorkspaceBackgroundColor,
                    selectedTool: isPDFPresentationModeEnabled ? .view : selectedTool,
                    pencilDoubleTapTool: pencilDoubleTapTool,
                    penColor: activePenColor,
                    penLineWidth: activePenLineWidth,
                    penType: activePenType,
                    penPressureStrength: activePenPressureStrength,
                    penStrokeSmoothingStrength: activePenStrokeSmoothingStrength,
                    highlighterCap: selectedHighlighterCap,
                    eraserSize: eraserSize,
                    isEraserPreviewVisible: !isPDFPresentationModeEnabled && isEraserOptionPresented && selectedTool == .eraser,
                    shapeType: selectedShapeType,
                    shapeLineColor: selectedShapeLineColor,
                    shapeFillColor: selectedShapeFillColor,
                    textBorderColor: selectedTextBorderColor,
                    textFillColor: selectedTextFillColor,
                    textColor: selectedTextColor,
                    pendingImage: pendingImageAnnotation,
                    pendingImageEditCommand: pendingImageEditCommand,
                    pendingShape: pendingShapeAnnotation,
                    pendingText: pendingTextAnnotation,
                    historyCommand: pendingHistoryCommand,
                    pageEditCommand: pendingPageEditCommand,
                    pageNavigationCommand: pendingPageNavigationCommand,
                    pageStructureRefreshCommand: pendingPageStructureRefreshCommand,
                    viewportPersistenceIdentifier: pdfViewportPersistenceIdentifier,
                    onActivateImageTool: activateImageEditMode,
                    onActivateShapeTool: activateShapeEditMode,
                    onActivateTextTool: activateTextEditMode,
                    onImageActionRequested: handleImageAction,
                    onBeginPenDrawing: {
                        // 펜 선을 그리기 시작하면 확장된 컬러 편집 영역을 기본 팔레트 모드로 되돌립니다.
                        editingPenColor = nil
                    },
                    onPencilDoubleTap: handlePencilDoubleTap,
                    onPresentationControlsReveal: revealPDFPresentationControls,
                    onCurrentPageChanged: { pageIndex in
                        if currentPDFPageIndex != pageIndex {
                            currentPDFPageIndex = pageIndex
                        }
                        if isPDFPresentationModeEnabled,
                           pageIndex == max(document.pageCount - 1, 0) {
                            revealPDFPresentationControls()
                        }
                    },
                    onZoomPercentageChanged: { percentage in
                        if currentPDFZoomPercentage != percentage {
                            currentPDFZoomPercentage = percentage
                        }
                    },
                    onImageSelectionChanged: { isSelected in
                        if isImageAnnotationSelected != isSelected {
                            isImageAnnotationSelected = isSelected
                        }
                    },
                    onSystemImageEditRequested: { image in
                        DispatchQueue.main.async {
                            presentSystemImageEditor(for: image)
                        }
                    },
                    onImageCropRequested: { image in
                        DispatchQueue.main.async {
                            imageCropEditorItem = PortalPDFImageCropEditorItem(image: image)
                        }
                    },
                    onShapeSelectionChanged: { isSelected in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if isShapeAnnotationSelected != isSelected {
                                isShapeAnnotationSelected = isSelected
                            }
                        }
                    },
                    onHistoryAvailabilityChanged: { canUndo, canRedo in
                        if canUndoPDFEdit != canUndo { canUndoPDFEdit = canUndo }
                        if canRedoPDFEdit != canRedo { canRedoPDFEdit = canRedo }
                    },
                    onDocumentChanged: {
                        scheduleLocalPDFAutosave()
                    }
                )
                // 편집 알약 이동 중에는 PDF 입력값이 변하지 않으므로 PDFView의
                // UIViewRepresentable 갱신을 생략해 화면 깜빡임과 재렌더링 비용을 줄입니다.
                .equatable()
                .ignoresSafeArea(edges: .bottom)

                if !isPDFPresentationModeEnabled {
                    // 편집 알약과 상세 편집 영역을 하나의 오버레이로 묶어 이동 위치를 공유합니다.
                    pdfMarkupEditorOverlay(in: geometry.size)
                }

                if isPDFPageSideListPresented {
                    HStack(spacing: 0) {
                        if pdfPageControlPosition == .right {
                            Spacer(minLength: 0)
                        }
                        PortalPDFPageSideListView(
                            document: document,
                            currentPageIndex: currentPDFPageIndex,
                            favoritePageIndexes: favoritePDFPageIndexes,
                            isPresentedOnLeft: pdfPageControlPosition == .left,
                            onSelectPage: { pageIndex in
                                currentPDFPageIndex = pageIndex
                                pendingPageNavigationCommand = PortalPDFPageNavigationCommand(
                                    pageIndex: pageIndex
                                )
                            },
                            onClose: {
                                withAnimation(pdfPageSideListSpringAnimation) {
                                    isPDFPageSideListPresented = false
                                }
                            }
                        )
                        .frame(width: min(max(geometry.size.width * 0.3, 190), 280))
                        if pdfPageControlPosition == .left {
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 58)
                    .transition(pdfPageSideListTransition)
                    .zIndex(9)
                }

                // 현재 페이지 정보는 PDF 이동·확대 및 편집 도구 입력을 가로채지 않는
                // 독립 오버레이로 우측 하단 안전영역 안쪽에 고정합니다.
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        if pdfPageControlPosition == .right {
                            Spacer(minLength: 0)
                        }
                        pdfPageIndicator(document: document)
                        if pdfPageControlPosition == .left {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .zIndex(10)
            }
            .animation(pdfPageSideListSpringAnimation, value: isPDFPageSideListPresented)
        }
    }

    /// 우측 페이지 목록의 팝 등장에 사용하는 통통 튀는 스프링 애니메이션입니다.
    var pdfPageSideListSpringAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 0.84, blendDuration: 0.08)
    }

    /// 설정한 좌우 위치에 맞춰 같은 스프링 효과가 화면 안쪽을 향해 시작되도록 합니다.
    var pdfPageSideListTransition: AnyTransition {
        let edge: Edge = pdfPageControlPosition == .left ? .leading : .trailing
        let anchor: UnitPoint = pdfPageControlPosition == .left ? .bottomLeading : .bottomTrailing
        return .move(edge: edge)
            .combined(with: .scale(scale: 0.88, anchor: anchor))
            .combined(with: .opacity)
    }

    /// PDFView 우측 최하단에 현재 페이지와 전체 페이지 수를 표시합니다.
    func pdfPageIndicator(document: PDFDocument) -> some View {
        let totalPageCount = max(document.pageCount, 1)
        let displayedPage = min(max(currentPDFPageIndex + 1, 1), totalPageCount)
        return HStack(spacing: 8) {
            Button {
                withAnimation(pdfPageSideListSpringAnimation) {
                    isPDFPageSideListPresented.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    if pdfPageControlPosition == .left {
                        pdfPageListIndicatorIcon
                    }
                    Text("\(displayedPage) / \(totalPageCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if pdfPageControlPosition == .right {
                        pdfPageListIndicatorIcon
                    }
                }
                .foregroundStyle(portalTheme.foregroundColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
                }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "현재 \(displayedPage) 페이지, 전체 \(totalPageCount) 페이지. 전체 페이지 목록 \(isPDFPageSideListPresented ? "닫기" : "열기")"
            )

            Text("\(currentPDFZoomPercentage)%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(portalTheme.foregroundColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
                }
                .accessibilityLabel("현재 확대 배율 \(currentPDFZoomPercentage) 퍼센트")
        }
    }

    var pdfPageListIndicatorIcon: some View {
        Image(systemName: isPDFPageSideListPresented ? "rectangle.stack.fill" : "rectangle.stack")
            .font(.caption.weight(.semibold))
            .accessibilityHidden(true)
    }

    func failedView(message: String) -> some View {
        VStack(spacing: 14) {
            Text("PDF 미리보기를 열 수 없습니다.")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("외부 앱에서 열기") {
                UIApplication.shared.open(item.url)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /**
     편집된 PDF 문서를 Portal 첨부 파일에 저장합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     */
    @MainActor
    func savePDFDocument() async {
        guard canSavePDFDocument, let document = loadedDocument else {
            saveStatus = .failed
            saveErrorMessage = "저장 가능한 PDF 첨부 파일을 찾지 못했습니다."
            return
        }
        saveErrorMessage = nil
        document.clearPortalImageAnnotationSelection()
        let localData = document.portalBaseDataRepresentation()
        let uploadData = document.portalFlattenedDataRepresentation() ?? document.dataRepresentation()
        guard let localData, let uploadData else {
            saveStatus = .failed
            saveErrorMessage = "편집된 PDF 데이터를 만들지 못했습니다."
            return
        }
        saveStatus = .saving
        do {
            /// 로컬 문서 또는 로컬 저장 설정이 켜진 문서는 서버 요청 전 편집본을 보관합니다.
            if shouldUseLocalPDFFile {
                try pdfLocalStorageRepository.save(localData, for: item)
            }
            /// 네이티브 문서 라이브러리에서 연 파일은 로컬 편집본 저장으로 완료합니다.
            guard item.localFileURL == nil else {
                localAutosaveController.hasPendingSave = false
                saveStatus = .saved
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if saveStatus == .saved { saveStatus = .idle }
                return
            }

            var request = URLRequest(url: item.url)
            request.httpMethod = "PATCH"
            request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let cookieHeader = item.cookieHeader {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let (responseData, response) = try await URLSession.shared.upload(for: request, from: uploadData)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                let serverMessage = String(data: responseData, encoding: .utf8)
                throw PortalPDFSaveError.httpStatus(
                    (response as? HTTPURLResponse)?.statusCode,
                    message: serverMessage
                )
            }
            /// 서버 저장이 완료된 편집본도 같은 로컬 캐시 경로에 확정해 다음 PDF 열기를 빠르게 합니다.
            if shouldUseLocalPDFFile {
                try? pdfLocalStorageRepository.save(localData, for: item)
            }
            localAutosaveController.hasPendingSave = false
            saveStatus = .saved
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if saveStatus == .saved {
                saveStatus = .idle
            }
        } catch {
            saveStatus = .failed
            saveErrorMessage = (error as? LocalizedError)?.errorDescription ?? "PDF 편집본을 저장하지 못했습니다. 네트워크 연결을 확인한 뒤 다시 시도해 주세요."
        }
    }

    /// 편집 이벤트가 연속으로 발생할 때 마지막 변경 후 잠시 뒤 로컬 PDF를 자동 저장합니다.
    @MainActor
    func scheduleLocalPDFAutosave() {
        // 로컬·서버 PDF 모두 미저장 변경 여부를 공유합니다. 서버 PDF는 앱이
        // 백그라운드로 전환될 때 이 상태를 기준으로 마지막 PATCH 저장을 수행합니다.
        localAutosaveController.hasPendingSave = true
        guard item.localFileURL != nil else { return }
        localAutosaveController.cancelScheduledSave()
        localAutosaveController.scheduledTask = Task { @MainActor in
            // 연속 필기 사이에는 PDF 전체 직렬화를 시작하지 않고, 사용자가 잠시 멈춘
            // 시점에만 저장해 펜 입력 프레임과 디스크 작업이 겹치지 않게 합니다.
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            persistPendingLocalPDFEdits()
        }
    }

    /// PDF 본문만 로컬 파일에 기록합니다. 편집 객체는 `.nfedit` 페이지 파일에 이미 원자 저장됩니다.
    @MainActor
    func persistPendingLocalPDFEdits() {
        guard localAutosaveController.hasPendingSave,
              item.localFileURL != nil,
              let document = loadedDocument,
              let data = document.portalBaseDataRepresentation() else { return }
        do {
            // 자동 저장은 화면 뒤 문서 목록까지 매번 갱신하지 않습니다. PDFView가 닫히면
            // 목록의 onDismiss가 수정 시각을 한 번 갱신하므로 편집 중 View invalidation을 막습니다.
            try pdfLocalStorageRepository.save(data, for: item, notifyObservers: false)
            localAutosaveController.hasPendingSave = false
        } catch {
            saveStatus = .failed
            saveErrorMessage = "PDF 편집 내용을 자동 저장하지 못했습니다."
        }
    }

    /**
     Photos Picker에서 선택한 이미지를 PDFView 삽입 요청 모델로 변환합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - item: 사용자가 선택한 Photos Picker 항목입니다.
     */
    @MainActor
    func loadSelectedImageAnnotation(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer { selectedImagePickerItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            // PhotosPicker의 원본 JPEG/HEIC 디코딩을 메인 액터 밖에서 끝냅니다.
            // 첫 이미지도 이동을 시작하기 전에 이미 GPU에 올릴 수 있는 래스터가 준비됩니다.
            let preparedImage = await Task.detached(priority: .userInitiated) {
                let raster = UIImage.pdfAnnotationRaster(from: data)
                let source = CGImageSourceCreateWithData(data as CFData, nil)
                let isAnimatedGIF = source.map { CGImageSourceGetCount($0) > 1 } ?? false
                return (raster, isAnimatedGIF)
            }.value
            guard let preparedRaster = preparedImage.0 else { return }
            let image = UIImage(cgImage: preparedRaster.cgImage, scale: 1, orientation: .up)
            switch imagePickerPurpose {
            case .insert:
                pendingImageAnnotation = PortalPDFPendingImage(
                    image: image,
                    sourceData: preparedImage.1 ? data : nil,
                    isAnimatedGIF: preparedImage.1
                )
            case .replace:
                pendingImageEditCommand = PortalPDFImageEditCommand(operation: .replace(image))
            }
        } catch {
            saveStatus = .failed
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if saveStatus == .failed {
                saveStatus = .idle
            }
        }
    }

    /// 선택 이미지를 Quick Look이 수정할 수 있는 임시 PNG 파일로 준비합니다.
    @MainActor
    func presentSystemImageEditor(for image: UIImage) {
        guard let imageData = image.pngData() else {
            saveErrorMessage = "선택 이미지를 시스템 편집기로 전달하지 못했습니다."
            return
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nf-image-edit-\(UUID().uuidString)")
            .appendingPathExtension("png")
        do {
            try imageData.write(to: fileURL, options: .atomic)
            systemImageEditorItem = PortalPDFSystemImageEditorItem(fileURL: fileURL)
        } catch {
            saveErrorMessage = "시스템 이미지 편집용 임시 파일을 만들지 못했습니다."
        }
    }

    /// 실제 기기 사진첩에서 최근 사진을 읽어 Grid 썸네일로 구성합니다.
    @MainActor
    func loadPhotoLibraryItems() async {
        isPhotoLibraryLoading = true
        photoLibraryMessage = nil
        photoLibraryItems = []
        defer { isPhotoLibraryLoading = false }

        let authorizationStatus = await requestPhotoLibraryAuthorization()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            photoLibraryMessage = "사진첩 접근 권한이 필요합니다."
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 60
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        guard assets.count > 0 else {
            photoLibraryMessage = "사진첩에 표시할 사진이 없습니다."
            return
        }

        let thumbnailSize = CGSize(
            width: 80 * UIScreen.main.scale,
            height: 80 * UIScreen.main.scale
        )
        for index in 0..<assets.count {
            guard !Task.isCancelled else { return }
            let asset = assets.object(at: index)
            guard let thumbnail = await loadPhotoAssetImage(asset, targetSize: thumbnailSize, deliveryMode: .fastFormat) else {
                continue
            }
            photoLibraryItems.append(PortalPhotoLibraryItem(asset: asset, thumbnail: thumbnail))
        }

        if photoLibraryItems.isEmpty {
            photoLibraryMessage = "사진첩 사진을 불러오지 못했습니다."
        }
    }

    /// 사진첩의 현재 권한을 확인하고, 최초 접근이면 시스템 권한 창을 표시합니다.
    func requestPhotoLibraryAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// PHAsset에서 Grid 또는 PDF 삽입에 사용할 이미지를 비동기로 읽습니다.
    func loadPhotoAssetImage(
        _ asset: PHAsset,
        targetSize: CGSize,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// GIF 삽입 시 프레임 컨테이너가 정지 썸네일로 소실되지 않도록 PHAsset 원본 데이터를 읽습니다.
    func loadPhotoAssetData(_ asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /** 로컬 저장 여부를 먼저 확인하고 최초 문서에 필요한 안내를 표시합니다. */
    @MainActor
    func preparePDFDocumentOpening() async {
        state = .loading
        localDownloadProgress = nil
        /// 설정이 꺼져 있어도 이미 저장된 문서는 로컬 파일을 우선 사용합니다.
        // PDFView가 편집 중인 파일을 자동 저장이 원자 교체하면 PDFKit의 지연 로딩이
        // 파일 변경을 감지해 타일을 다시 만들 수 있습니다. 메모리 Data로 문서를 열어
        // 화면 문서와 디스크 저장 파일의 생명주기를 분리합니다.
        if let localData = pdfLocalStorageRepository.data(for: item),
           let localDocument = PDFDocument(data: localData),
           localDocument.pageCount > 0 {
            _ = localDocument.restorePortalEditableAnnotations()
            state = .loaded(localDocument)
            return
        }
        initialOpenPrompt = isPDFLocalStorageEnabled ? .localStorageEnabled : .localStorageDisabled
    }

    /** PDF를 다운로드하고 선택한 방식에 따라 저장한 뒤 PDFView를 표시합니다. */
    @MainActor
    func downloadAndOpenPDF(saveLocally: Bool) async {
        state = .loading
        localDownloadProgress = saveLocally ? 0 : nil
        do {
            var request = URLRequest(url: item.url)
            request.setValue("application/pdf, application/octet-stream;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
            if let cookieHeader = item.cookieHeader {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let downloader = PortalPDFProgressDownloader { progress in
                guard saveLocally else { return }
                Task { @MainActor in
                    localDownloadProgress = progress
                }
            }
            let (data, response) = try await downloader.download(request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                throw PortalPDFPreviewError.downloadFailed
            }
            guard data.startsWithPDFSignature || httpResponse.isPDFContentType else {
                throw PortalPDFPreviewError.unsupportedFile
            }
            let documentData: Data
            if saveLocally {
                try pdfLocalStorageRepository.save(data, for: item)
                localDownloadProgress = 1
                guard let storedData = pdfLocalStorageRepository.data(for: item) else {
                    throw PortalPDFPreviewError.localSaveFailed
                }
                documentData = storedData
            } else {
                documentData = data
            }
            guard let document = PDFDocument(data: documentData), document.pageCount > 0 else {
                throw PortalPDFPreviewError.invalidPDF
            }
            _ = document.restorePortalEditableAnnotations()
            state = .loaded(document)
        } catch let error as PortalPDFPreviewError {
            state = .failed(error.localizedDescription)
        } catch {
            state = .failed(saveLocally
                ? "PDF를 로컬에 저장하는 중 오류가 발생했습니다."
                : "첨부 파일을 불러오는 중 오류가 발생했습니다.")
        }
        localDownloadProgress = nil
    }
}

/**
 편집 알약 이동 제스처를 PDF 미리보기 상위 화면과 분리하는 전용 컨테이너입니다. ( J.D.H )

 [Note]
 - 이동 중 translation은 이 하위 뷰의 GestureState에서만 갱신합니다.
 - 상위 PortalPDFPreviewView에는 드래그 종료 시 최종 위치만 전달합니다.
 - 이동 프레임에는 모든 암시적 애니메이션을 비활성화해 손가락을 즉시 따라갑니다.

 - Version: 1.0.0
 - Date: 2026.08.04
 */
