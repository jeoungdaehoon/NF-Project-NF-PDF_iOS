//
// PortalPDFKitView.swift
// NF
//
// PDFKit bridge, gesture coordination, viewport restoration, and editing coordinator.
//

import ImageIO
import CoreText
import Darwin
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

/// 전체 경로 복사 방식의 Undo 스냅샷이 필기 수에 비례해 메모리를 과도하게 점유하지 않도록 제한합니다.
enum PortalPDFHistoryPolicy {
    static func maximumUndoCount(maximumPageEditUnitCount: Int) -> Int {
        switch maximumPageEditUnitCount {
        case 60...:
            return 6
        case 30...:
            return 12
        default:
            return 20
        }
    }

    static func editUnitCount(for annotations: [PDFAnnotation]) -> Int {
        annotations.reduce(0) { count, annotation in
            guard annotation.isPortalInkAnnotation else { return count + 1 }
            return count + max(1, annotation.paths?.count ?? 0)
        }
    }

    static func maximumUndoCount(for document: PDFDocument) -> Int {
        var maximumPageEditUnitCount = 0
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            maximumPageEditUnitCount = max(
                maximumPageEditUnitCount,
                editUnitCount(for: page.annotations)
            )
        }
        return maximumUndoCount(maximumPageEditUnitCount: maximumPageEditUnitCount)
    }
}

enum PortalPDFProcessMemory {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    integerPointer,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

final class PortalPDFView: PDFView {
    var selectionChangedObserver: NSObjectProtocol?
    weak var protectedTextInputView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        observeSelectionChanges()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeSelectionChanges()
    }

    deinit {
        if let selectionChangedObserver {
            NotificationCenter.default.removeObserver(selectionChangedObserver)
        }
    }

    var suppressesDocumentActions = false {
        didSet {
            guard suppressesDocumentActions, oldValue != suppressesDocumentActions else { return }
            cancelDocumentActions()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard !suppressesDocumentActions else { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    /// PDFKit이 렌더링 도중 선택 제스처를 다시 붙이더라도 필기 모드에서는 선택을 즉시 취소합니다.
    func observeSelectionChanges() {
        selectionChangedObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.suppressesDocumentActions else { return }
            self.cancelDocumentActions()
        }
    }

    func cancelDocumentActions() {
        if currentSelection != nil {
            clearSelection()
        }
        dismissDocumentMenus()
    }

    func dismissDocumentMenus() {
        if #available(iOS 16.0, *) {
            recursiveSubviewsIncludingSelf
                .filter { view in
                    guard let protectedTextInputView else { return true }
                    return view !== protectedTextInputView
                        && !view.isDescendant(of: protectedTextInputView)
                }
                .flatMap(\.interactions)
                .compactMap { $0 as? UIEditMenuInteraction }
                .forEach { $0.dismissMenu() }
        }
    }
}

/**
 PDFKit의 PDFView를 SwiftUI에서 사용할 수 있게 감싸고 PDF 주석 편집 제스처를 연결하는 UIViewRepresentable 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalPDFPreviewView``
 */
struct PortalPDFKitView: UIViewRepresentable {
    /// PDFKit이 표시할 PDF 문서입니다.
    let document: PDFDocument
    /// PDF 페이지의 이동 방향과 연속/한 장 표시 방식입니다.
    let displayStyle: PortalPDFDisplayStyle
    /// 한 화면에 표시할 PDF 페이지 수입니다.
    let pageLayout: PortalPDFPageLayout
    /// PDF 페이지 바깥 편집 캔버스에 적용할 현재 포털 테마 배경색입니다.
    let viewerBackgroundColor: Color
    /// 현재 선택된 PDF 편집 도구입니다.
    let selectedTool: PortalPDFMarkupTool
    /// Apple Pencil 이중 탭으로 팬슬과 왕복 전환할 사용자 설정 편집 모드입니다.
    let pencilDoubleTapTool: PortalPDFPencilDoubleTapTool
    /// 펜 도구로 PDF 주석을 추가할 때 사용할 색상입니다.
    let penColor: Color
    /// 펜 도구로 PDF 주석을 추가할 때 사용할 PDF Page 좌표계 기준 굵기입니다.
    let penLineWidth: CGFloat
    /// 펜 도구의 굵기 적용 방식입니다.
    let penType: PortalPDFPenType
    /// 압력 타입에서 센서 압력에 따른 굵기 변화량입니다. 1.0은 기본 반응입니다.
    let penPressureStrength: CGFloat
    /// 펜을 떼는 순간 발생하는 끝 삐침을 완화할 강도입니다.
    let penStrokeSmoothingStrength: CGFloat
    /// 형광펜 시작·끝 부분의 표시 방식입니다.
    let highlighterCap: PortalPDFHighlighterCap
    /// 지우개가 적용되는 화면 기준 지름입니다.
    let eraserSize: CGFloat
    /// 지우개 상세창이 열린 동안 PDFView에 크기 미리보기를 표시할지 여부입니다.
    let isEraserPreviewVisible: Bool
    /// 박스 도구로 추가할 현재 도형 종류입니다.
    let shapeType: PortalPDFShapeType
    /// 박스 도구로 추가하거나 선택한 도형에 적용할 선 색상입니다.
    let shapeLineColor: Color
    /// 박스 도구로 추가하거나 선택한 도형에 적용할 배경 색상입니다.
    let shapeFillColor: Color
    /// 텍스트 박스에 적용할 테두리 색상입니다.
    let textBorderColor: Color
    /// 텍스트 박스에 적용할 배경 색상입니다.
    let textFillColor: Color
    /// 텍스트 박스에 적용할 문자 색상입니다.
    let textColor: Color
    /// PDFView에 1회 삽입할 이미지 주석 요청입니다.
    let pendingImage: PortalPDFPendingImage?
    /// 선택 이미지에 1회 적용할 편집 명령입니다.
    let pendingImageEditCommand: PortalPDFImageEditCommand?
    /// PDFView에 1회 삽입할 도형 주석 요청입니다.
    let pendingShape: PortalPDFPendingShape?
    /// PDFView에 1회 삽입할 텍스트 박스 주석 요청입니다.
    let pendingText: PortalPDFPendingText?
    /// 실행 취소·다시 실행 1회 명령입니다.
    let historyCommand: PortalPDFHistoryCommand?
    /// 현재 페이지 아래에 빈 페이지를 추가하거나 현재 페이지를 복제하는 명령입니다.
    let pageEditCommand: PortalPDFPageEditCommand?
    /// 전체 페이지 목록에서 선택한 페이지로 이동하는 명령입니다.
    let pageNavigationCommand: PortalPDFPageNavigationCommand?
    /// 전체 페이지 편집에서 삭제·복제·순서 변경 후 PDFView를 갱신하는 명령입니다.
    let pageStructureRefreshCommand: PortalPDFPageStructureRefreshCommand?
    /// 마지막 확대·스크롤 위치를 문서별로 저장할 안정적인 식별자입니다.
    let viewportPersistenceIdentifier: String
    /// 이미지 주석을 길게 눌러 편집 모드로 진입했을 때 SwiftUI 하단 도구 상태를 갱신하는 이벤트입니다.
    let onActivateImageTool: () -> Void
    /// 도형 주석을 길게 눌러 편집 모드로 진입했을 때 SwiftUI 하단 도구 상태를 갱신하는 이벤트입니다.
    let onActivateShapeTool: () -> Void
    /// 다른 객체 편집 모드에서 텍스트 박스를 선택했을 때 SwiftUI 하단 도구 상태를 갱신하는 이벤트입니다.
    let onActivateTextTool: () -> Void
    /// 이미지 말풍선 메뉴에서 선택한 편집 기능을 SwiftUI 상태로 전달하는 이벤트입니다.
    let onImageActionRequested: (PortalPDFImageAction) -> Void
    /// 펜 드로잉이 시작될 때 확장된 컬러 편집 영역을 기본 모드로 되돌리는 이벤트입니다.
    let onBeginPenDrawing: () -> Void
    /// Apple Pencil 이중 탭을 SwiftUI 편집 도구 왕복 전환으로 전달합니다.
    let onPencilDoubleTap: () -> Void
    /// 프레젠테이션 중 세 손가락 위·아래 스와이프를 상단 제어 UI 표시 요청으로 전달합니다.
    let onPresentationControlsReveal: () -> Void
    /// PDFView에서 현재 표시 중인 페이지 번호를 SwiftUI에 전달합니다.
    let onCurrentPageChanged: (Int) -> Void
    /// PDFView의 현재 확대 배율을 정수 퍼센트로 SwiftUI에 실시간 전달합니다.
    let onZoomPercentageChanged: (Int) -> Void
    /// 실제 이미지 Annotation 선택 여부가 변경될 때 SwiftUI 패널 표시 상태를 갱신합니다.
    let onImageSelectionChanged: (Bool) -> Void
    /// 선택 이미지의 시스템 Markup 편집을 SwiftUI에 요청합니다.
    let onSystemImageEditRequested: (UIImage) -> Void
    /// 선택 이미지의 전용 자르기 화면 표시를 SwiftUI에 요청합니다.
    let onImageCropRequested: (UIImage) -> Void
    /// 실제 도형 Annotation 선택 여부가 변경될 때 SwiftUI 상태를 갱신합니다.
    let onShapeSelectionChanged: (Bool) -> Void
    /// 실행 취소·다시 실행 가능 여부가 변경될 때 기본 편집 박스를 갱신합니다.
    let onHistoryAvailabilityChanged: (Bool, Bool) -> Void
    /// PDF Annotation의 내용·위치·크기 등이 변경되었음을 자동 저장 흐름에 전달합니다.
    let onDocumentChanged: () -> Void

    /**
     PDFView 인스턴스를 생성합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - context: UIViewRepresentable Context 정보입니다.
     - Returns: `PDFView`
    */
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PortalPDFView()
        pdfView.autoScales = true
        // PDFKit 기본 확대 한도보다 더 세밀하게 문서와 주석을 확인할 수 있도록 허용합니다.
        pdfView.maxScaleFactor = 10
        applyDisplayStyle(
            displayStyle,
            pageLayout: pageLayout,
            to: pdfView,
            preservingCurrentPage: false
        )
        applyViewerBackground(to: pdfView)
        pdfView.pageOverlayViewProvider = context.coordinator
        context.coordinator.updatePencilDoubleTapHandler(onPencilDoubleTap)
        context.coordinator.updatePresentationControlsRevealHandler(onPresentationControlsReveal)
        context.coordinator.updateCurrentPageChangedHandler(onCurrentPageChanged)
        context.coordinator.updateZoomPercentageChangedHandler(onZoomPercentageChanged)
        context.coordinator.attach(to: pdfView)
        return pdfView
    }

    /**
     SwiftUI State 변경을 PDFView에 반영합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - pdfView: 갱신 대상 PDFView 입니다.
        - context: UIViewRepresentable Context 정보입니다.
     */
    func updateUIView(_ pdfView: PDFView, context: Context) {
        // 저장된 뷰포트가 있는 문서는 PDFKit의 최초 자동 맞춤을 실행하지 않습니다.
        // document 연결 직후 autoScales를 켜면 PDFKit이 문서를 화면 중앙으로 먼저 이동한 뒤
        // Coordinator의 비동기 위치 복원이 실행되어, 재진입할 때 중앙으로 튀는 화면이 노출됩니다.
        let hasStoredViewport = PortalPDFViewportStore.load(
            for: viewportPersistenceIdentifier
        ) != nil
        // 페이지 편집 데이터는 PDF 본문과 분리된 .nfedit 파일에서 먼저 복원합니다.
        // 기존 Annotation은 선택·이동 제스처 호환용 숨은 프록시로만 유지합니다.
        context.coordinator.configurePageEditPersistence(
            identifier: viewportPersistenceIdentifier,
            document: document
        )
        // PDFKit은 고배율에서 Ink bounds 전체를 래스터화하므로 문서 연결 전에 숨기고,
        // 페이지 오버레이의 Core Animation 경로가 별도 편집 모델을 직접 그리게 합니다.
        context.coordinator.activatePersistentInkOverlay(for: document, in: pdfView)
        if pdfView.document !== document {
            pdfView.autoScales = !hasStoredViewport
            pdfView.document = document
            // 문서를 다시 연결해도 사용자 확대 한도가 PDFKit 기본값으로 돌아가지 않게 유지합니다.
            pdfView.maxScaleFactor = 10
        }

        if pdfView.displayMode != pageLayout.displayMode(for: displayStyle) ||
            pdfView.displayDirection != displayStyle.displayDirection {
            applyDisplayStyle(
                displayStyle,
                pageLayout: pageLayout,
                to: pdfView,
                preservingCurrentPage: !hasStoredViewport,
                allowsAutoScaling: !hasStoredViewport
            )
        }

        /// PDFView 외부와 실제 페이지를 담는 documentView까지 동일한 테마 배경으로 맞춥니다.
        applyViewerBackground(to: pdfView)

        // 이동 제스처 중에는 SwiftUI 상위 뷰가 반복 갱신되더라도 PDF 입력값은 동일합니다.
        // Coordinator가 마지막으로 반영한 입력과 같으면 PDF 주석/스크롤 제스처를 다시
        // 설정하지 않아 PDFKit 타일 재렌더링으로 인한 깜빡임을 차단합니다.
        context.coordinator.updateActivationHandler(onActivateImageTool)
        context.coordinator.updateShapeActivationHandler(onActivateShapeTool)
        context.coordinator.updateTextActivationHandler(onActivateTextTool)
        context.coordinator.updateImageActionHandler(onImageActionRequested)
        context.coordinator.updatePenDrawingHandler(onBeginPenDrawing)
        context.coordinator.updatePencilDoubleTapHandler(onPencilDoubleTap)
        context.coordinator.updatePresentationControlsRevealHandler(onPresentationControlsReveal)
        context.coordinator.updateCurrentPageChangedHandler(onCurrentPageChanged)
        context.coordinator.updateZoomPercentageChangedHandler(onZoomPercentageChanged)
        context.coordinator.updateImageSelectionHandler(onImageSelectionChanged)
        context.coordinator.updateSystemImageEditHandler(onSystemImageEditRequested)
        context.coordinator.updateImageCropHandler(onImageCropRequested)
        context.coordinator.updateShapeSelectionHandler(onShapeSelectionChanged)
        context.coordinator.updateDocumentChangedHandler(onDocumentChanged)
        context.coordinator.updateHistoryAvailabilityHandler(onHistoryAvailabilityChanged)
        context.coordinator.configureViewportPersistence(
            identifier: viewportPersistenceIdentifier,
            document: document,
            in: pdfView
        )
        context.coordinator.reportCurrentPageIndex(in: pdfView)
        context.coordinator.reportZoomPercentage(in: pdfView)
        context.coordinator.updateEraserSize(eraserSize)
        context.coordinator.updateEraserPreviewVisibility(isEraserPreviewVisible)
        context.coordinator.applyHistoryCommandIfNeeded(historyCommand, in: pdfView)
        context.coordinator.applyPageEditCommandIfNeeded(pageEditCommand, in: pdfView)
        context.coordinator.applyPageNavigationCommandIfNeeded(pageNavigationCommand, in: pdfView)
        context.coordinator.applyPageStructureRefreshCommandIfNeeded(pageStructureRefreshCommand, in: pdfView)
        guard context.coordinator.shouldApplyRenderState(
            document: document,
            selectedTool: selectedTool,
            penColor: UIColor(penColor),
            penLineWidth: penLineWidth,
            penType: penType,
            penPressureStrength: penPressureStrength,
            penStrokeSmoothingStrength: penStrokeSmoothingStrength,
            highlighterCap: highlighterCap,
            shapeType: shapeType,
            shapeLineColor: UIColor(shapeLineColor),
            shapeFillColor: UIColor(shapeFillColor),
            textBorderColor: UIColor(textBorderColor),
            textFillColor: UIColor(textFillColor),
            textColor: UIColor(textColor),
            pendingImage: pendingImage,
            pendingImageEditCommand: pendingImageEditCommand,
            pendingShape: pendingShape,
            pendingText: pendingText
        ) else {
            return
        }

        context.coordinator.updateSelectedTool(selectedTool, in: pdfView)
        context.coordinator.updatePenStyle(
            color: UIColor(penColor),
            lineWidth: penLineWidth,
            penType: penType,
            pressureStrength: penPressureStrength,
            strokeSmoothingStrength: penStrokeSmoothingStrength,
            highlighterCap: highlighterCap,
            in: pdfView
        )
        context.coordinator.updateShapeType(shapeType)
        context.coordinator.updateShapeStyle(
            lineColor: UIColor(shapeLineColor),
            fillColor: UIColor(shapeFillColor),
            in: pdfView
        )
        context.coordinator.updateTextStyle(
            borderColor: UIColor(textBorderColor),
            fillColor: UIColor(textFillColor),
            textColor: UIColor(textColor),
            in: pdfView
        )
        context.coordinator.addPendingImageIfNeeded(pendingImage, in: pdfView)
        context.coordinator.applyPendingImageEditCommandIfNeeded(pendingImageEditCommand, in: pdfView)
        context.coordinator.addPendingShapeIfNeeded(pendingShape, in: pdfView)
        context.coordinator.addPendingTextIfNeeded(
            pendingText,
            borderColor: UIColor(textBorderColor),
            fillColor: UIColor(textFillColor),
            textColor: UIColor(textColor),
            in: pdfView
        )
    }

    /// PDFView가 닫히기 직전 마지막 확대·스크롤 상태를 즉시 저장합니다.
    static func dismantleUIView(_ pdfView: PDFView, coordinator: Coordinator) {
        let document = pdfView.document
        coordinator.prepareForDismantle()
        pdfView.pageOverlayViewProvider = nil
        // PDFKit에서 먼저 문서를 분리한 뒤 저장 객체의 표시 플래그를 복원해야
        // 닫히는 12배 화면에서 거대한 Ink 래스터가 다시 만들어지지 않습니다.
        pdfView.document = nil
        if let document {
            PortalPDFInkDisplaySuppression.restore(in: document)
        }
        coordinator.persistentInkOverlayDocumentID = nil
    }

    /**
     PDFView 제스처 처리를 담당하는 Coordinator를 생성합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Returns: ``Coordinator``
     */
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// PDFKit 내부 문서 컨테이너가 시스템 기본색으로 캔버스를 덮지 않도록 함께 갱신합니다.
    func applyViewerBackground(to pdfView: PDFView) {
        let backgroundColor = UIColor(viewerBackgroundColor)
        pdfView.backgroundColor = backgroundColor
        pdfView.documentView?.backgroundColor = backgroundColor
    }

    /// 보기 스타일을 변경해도 사용자가 보고 있던 페이지는 그대로 유지합니다.
    func applyDisplayStyle(
        _ style: PortalPDFDisplayStyle,
        pageLayout: PortalPDFPageLayout,
        to pdfView: PDFView,
        preservingCurrentPage: Bool,
        allowsAutoScaling: Bool = true
    ) {
        let currentPage = preservingCurrentPage ? pdfView.currentPage : nil
        pdfView.usePageViewController(false, withViewOptions: nil)
        pdfView.displayDirection = style.displayDirection
        pdfView.displayMode = pageLayout.displayMode(for: style)
        pdfView.displaysAsBook = false
        pdfView.displaysPageBreaks = true
        // PDFKit의 PageViewController는 1장 보기에서만 안정적으로 동작합니다.
        // 2장 보기에서는 twoUp 레이아웃 자체가 좌우 페이지 묶음을 관리합니다.
        if style.usesPageViewController && pageLayout == .singlePage {
            pdfView.usePageViewController(true, withViewOptions: nil)
        }
        pdfView.autoScales = allowsAutoScaling
        if let currentPage {
            DispatchQueue.main.async { [weak pdfView] in
                pdfView?.go(to: currentPage)
            }
        }
    }
}

/// PDF 입력값이 실제로 변경된 경우에만 PDFView를 다시 갱신하도록 비교합니다.
extension PortalPDFKitView: Equatable {
    static func == (lhs: PortalPDFKitView, rhs: PortalPDFKitView) -> Bool {
        lhs.document === rhs.document &&
            lhs.displayStyle == rhs.displayStyle &&
            lhs.pageLayout == rhs.pageLayout &&
            areColorsEqual(lhs.viewerBackgroundColor, rhs.viewerBackgroundColor) &&
            lhs.selectedTool == rhs.selectedTool &&
            lhs.pencilDoubleTapTool == rhs.pencilDoubleTapTool &&
            lhs.penLineWidth == rhs.penLineWidth &&
            lhs.penType == rhs.penType &&
            lhs.penPressureStrength == rhs.penPressureStrength &&
            lhs.penStrokeSmoothingStrength == rhs.penStrokeSmoothingStrength &&
            lhs.highlighterCap == rhs.highlighterCap &&
            lhs.eraserSize == rhs.eraserSize &&
            lhs.isEraserPreviewVisible == rhs.isEraserPreviewVisible &&
            areColorsEqual(lhs.penColor, rhs.penColor) &&
            lhs.shapeType == rhs.shapeType &&
            areColorsEqual(lhs.shapeLineColor, rhs.shapeLineColor) &&
            areColorsEqual(lhs.shapeFillColor, rhs.shapeFillColor) &&
            areColorsEqual(lhs.textBorderColor, rhs.textBorderColor) &&
            areColorsEqual(lhs.textFillColor, rhs.textFillColor) &&
            areColorsEqual(lhs.textColor, rhs.textColor) &&
            lhs.pendingImage == rhs.pendingImage &&
            lhs.pendingImageEditCommand == rhs.pendingImageEditCommand &&
            lhs.pendingShape == rhs.pendingShape &&
            lhs.pendingText == rhs.pendingText &&
            lhs.historyCommand == rhs.historyCommand &&
            lhs.pageEditCommand == rhs.pageEditCommand &&
            lhs.pageNavigationCommand == rhs.pageNavigationCommand &&
            lhs.pageStructureRefreshCommand == rhs.pageStructureRefreshCommand &&
            lhs.viewportPersistenceIdentifier == rhs.viewportPersistenceIdentifier
    }

    /// SwiftUI Color를 동일한 RGBA 값으로 변환해 펜 색상 변경 여부를 비교합니다.
    static func areColorsEqual(_ lhs: Color, _ rhs: Color) -> Bool {
        var lhsRed: CGFloat = 0
        var lhsGreen: CGFloat = 0
        var lhsBlue: CGFloat = 0
        var lhsAlpha: CGFloat = 0
        var rhsRed: CGFloat = 0
        var rhsGreen: CGFloat = 0
        var rhsBlue: CGFloat = 0
        var rhsAlpha: CGFloat = 0

        let lhsColor = UIColor(lhs)
        let rhsColor = UIColor(rhs)
        guard lhsColor.getRed(&lhsRed, green: &lhsGreen, blue: &lhsBlue, alpha: &lhsAlpha),
              rhsColor.getRed(&rhsRed, green: &rhsGreen, blue: &rhsBlue, alpha: &rhsAlpha) else {
            return lhsColor == rhsColor
        }

        return lhsRed == rhsRed && lhsGreen == rhsGreen && lhsBlue == rhsBlue && lhsAlpha == rhsAlpha
    }
}

/**
 `UIPanGestureRecognizer`의 이동 임계값 없이 펜 터치를 즉시 시작하고,
 한 프레임 사이에 수집된 coalesced touch 좌표를 모두 전달하는 전용 제스처입니다.
 */
final class PortalPDFPenGestureRecognizer: UIGestureRecognizer {
    /// 현재 이벤트에서 수집한 PDFView 좌표계 터치 지점입니다.
    private(set) var sampledLocations: [CGPoint] = []
    /// 현재 이벤트에서 수집한 터치 압력값입니다. 좌표 배열과 같은 순서로 유지합니다.
    private(set) var sampledPressures: [CGFloat] = []
    /// 편집 타입에 따라 허용할 입력 장치를 명시합니다. `nil`이면 모든 입력을 허용합니다.
    var requiredTouchType: UITouch.TouchType?
    /// 여러 손가락 입력이 섞이지 않도록 최초 터치만 추적합니다.
    weak var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if trackedTouch != nil {
            state = .cancelled
            return
        }
        guard touches.count == 1,
              let touch = touches.first,
              let view else {
            state = .failed
            return
        }
        // iPad 팬슬 모드에 들어온 손가락 터치는 즉시 실패시켜 PDF 스크롤 제스처로 전달합니다.
        guard requiredTouchType == nil || touch.type == requiredTouchType else {
            state = .failed
            return
        }
        trackedTouch = touch
        let samples = samples(for: touch, event: event, in: view)
        sampledLocations = samples.locations
        sampledPressures = samples.pressures
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch,
              touches.contains(where: { $0 === trackedTouch }),
              let view else { return }
        let samples = samples(for: trackedTouch, event: event, in: view)
        sampledLocations = samples.locations
        sampledPressures = samples.pressures
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch,
              touches.contains(where: { $0 === trackedTouch }),
              let view else { return }
        let samples = samples(for: trackedTouch, event: event, in: view)
        sampledLocations = samples.locations
        sampledPressures = samples.pressures
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        sampledLocations = []
        sampledPressures = []
        trackedTouch = nil
    }

    /// UIKit이 한 프레임 사이에 합쳐 보관한 실제 터치 좌표를 누락 없이 반환합니다.
    func samples(for touch: UITouch, event: UIEvent?, in view: UIView) -> (locations: [CGPoint], pressures: [CGFloat]) {
        let touches = event?.coalescedTouches(for: touch) ?? [touch]
        let locations = touches.map { $0.location(in: view) }
        let pressures = touches.map { touch -> CGFloat in
            guard touch.maximumPossibleForce > 0 else { return 0.5 }
            return min(1, max(0, touch.force / touch.maximumPossibleForce))
        }
        return (locations, pressures)
    }
}

/// PDFKit Pan 인식 임계값과 무관하게 지우개 터치를 즉시 전달하는 전용 Gesture Recognizer입니다.
final class PortalPDFEraserGestureRecognizer: UIGestureRecognizer {
    weak var trackedTouch: UITouch?
    private(set) var sampledLocations: [CGPoint] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil else {
            // 두 번째 손가락이 추가되면 지우개를 취소해 PDFView Pinch/두 손가락 이동에 입력을 넘깁니다.
            state = .cancelled
            return
        }
        guard touches.count == 1, let touch = touches.first, let view else {
            state = .failed
            return
        }
        trackedTouch = touch
        sampledLocations = samples(for: touch, event: event, in: view)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch,
              touches.contains(where: { $0 === trackedTouch }),
              let view else { return }
        sampledLocations = samples(for: trackedTouch, event: event, in: view)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch,
              touches.contains(where: { $0 === trackedTouch }),
              let view else { return }
        sampledLocations = samples(for: trackedTouch, event: event, in: view)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        sampledLocations = []
        trackedTouch = nil
    }

    func samples(for touch: UITouch, event: UIEvent?, in view: UIView) -> [CGPoint] {
        (event?.coalescedTouches(for: touch) ?? [touch]).map { $0.location(in: view) }
    }
}

/// 텍스트 박스의 첫 터치를 관찰하되 다른 탭·드래그·UITextView 입력은 방해하지 않는 전용 인식기입니다.
final class PortalPDFTextTouchDownGestureRecognizer: UIGestureRecognizer {
    var onTouchDown: ((CGPoint) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, let view else {
            state = .failed
            return
        }
        onTouchDown?(touch.location(in: view))
        // 터치 시작 위치만 관찰한 뒤 즉시 실패 처리해 기존 이동·길게 누르기·문자 입력을 그대로 전달합니다.
        state = .failed
    }
}

/// 텍스트 박스를 이동하지 않고 탭했을 때 박스 위에 표시하는 말풍선형 작업 메뉴입니다.
final class PortalPDFTextActionMenuView: UIView {
    enum Action: CaseIterable {
        case delete
        case duplicate
        case copy
        case edit
        case bringToFront
        case sendToBack

        var title: String {
            switch self {
            case .delete: return "삭제"
            case .duplicate: return "복제"
            case .copy: return "복사"
            case .edit: return "편집"
            case .bringToFront: return "최상단"
            case .sendToBack: return "최하단"
            }
        }

        var systemImageName: String {
            switch self {
            case .delete: return "trash"
            case .duplicate: return "plus.square.on.square"
            case .copy: return "doc.on.doc"
            case .edit: return "pencil"
            case .bringToFront: return "square.3.layers.3d.top.filled"
            case .sendToBack: return "square.3.layers.3d.bottom.filled"
            }
        }
    }

    var onAction: ((Action) -> Void)?
    var showsTailAtTop = false {
        didSet { setNeedsLayout() }
    }
    private let panelView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let stackView = UIStackView()
    private let tailView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        panelView.layer.cornerRadius = 13
        panelView.layer.masksToBounds = true
        addSubview(panelView)

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 4
        panelView.contentView.addSubview(stackView)

        Action.allCases.forEach { action in
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(
                systemName: action.systemImageName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            )
            configuration.imagePlacement = .top
            configuration.imagePadding = 5
            configuration.title = action.title
            configuration.baseForegroundColor = action == .delete ? .systemRed : .white
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 1, bottom: 5, trailing: 1)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 9, weight: .medium)
                return outgoing
            }
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = "텍스트 박스 \(action.title)"
            button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }

        tailView.backgroundColor = UIColor(white: 0.16, alpha: 0.96)
        tailView.isUserInteractionEnabled = false
        addSubview(tailView)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let tailSide: CGFloat = 12
        let panelHeight = bounds.height - 6
        panelView.frame = CGRect(
            x: 0,
            y: showsTailAtTop ? 6 : 0,
            width: bounds.width,
            height: panelHeight
        )
        stackView.frame = panelView.bounds.insetBy(dx: 7, dy: 2)
        tailView.bounds = CGRect(x: 0, y: 0, width: tailSide, height: tailSide)
        tailView.center = CGPoint(
            x: bounds.midX,
            y: showsTailAtTop ? 6 : panelHeight
        )
        tailView.transform = CGAffineTransform(rotationAngle: .pi / 4)
        sendSubviewToBack(tailView)
    }
}

/// 선택 이미지의 하단 편집 패널을 대체하는 말풍선 작업 메뉴 명령입니다.
enum PortalPDFImageAction: CaseIterable {
    case replace
    case resetSize
    case rotateClockwise
    case flipHorizontal
    case crop
    case openSystemEditor
    case bringToFront
    case sendToBack

    var title: String {
        switch self {
        case .replace: return "변경"
        case .resetSize: return "원본 크기"
        case .rotateClockwise: return "회전"
        case .flipHorizontal: return "좌우 반전"
        case .crop: return "자르기"
        case .openSystemEditor: return "시스템 편집"
        case .bringToFront: return "최상단"
        case .sendToBack: return "최하단"
        }
    }

    var systemImageName: String {
        switch self {
        case .replace: return "photo.on.rectangle"
        case .resetSize: return "arrow.counterclockwise"
        case .rotateClockwise: return "rotate.right"
        case .flipHorizontal: return "arrow.left.and.right"
        case .crop: return "crop"
        case .openSystemEditor: return "pencil.and.outline"
        case .bringToFront: return "square.3.layers.3d.top.filled"
        case .sendToBack: return "square.3.layers.3d.bottom.filled"
        }
    }
}

/// 이미지를 선택했을 때 이미지 위에 표시하는 말풍선형 편집 메뉴입니다.
final class PortalPDFImageActionMenuView: UIView {
    var onAction: ((PortalPDFImageAction) -> Void)?
    var showsTailAtTop = false {
        didSet { setNeedsLayout() }
    }
    private let panelView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let stackView = UIStackView()
    private let tailView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        panelView.layer.cornerRadius = 13
        panelView.layer.masksToBounds = true
        addSubview(panelView)

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 4
        panelView.contentView.addSubview(stackView)

        PortalPDFImageAction.allCases.forEach { action in
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(
                systemName: action.systemImageName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            )
            configuration.imagePlacement = .top
            configuration.imagePadding = 5
            configuration.title = action.title
            configuration.baseForegroundColor = .white
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 1, bottom: 5, trailing: 1)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 9, weight: .medium)
                return outgoing
            }
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = "선택 이미지 \(action.title)"
            button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }

        tailView.backgroundColor = UIColor(white: 0.16, alpha: 0.96)
        tailView.isUserInteractionEnabled = false
        addSubview(tailView)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let tailSide: CGFloat = 12
        let panelHeight = bounds.height - 6
        panelView.frame = CGRect(
            x: 0,
            y: showsTailAtTop ? 6 : 0,
            width: bounds.width,
            height: panelHeight
        )
        stackView.frame = panelView.bounds.insetBy(dx: 7, dy: 2)
        tailView.bounds = CGRect(x: 0, y: 0, width: tailSide, height: tailSide)
        tailView.center = CGPoint(
            x: bounds.midX,
            y: showsTailAtTop ? 6 : panelHeight
        )
        tailView.transform = CGAffineTransform(rotationAngle: .pi / 4)
        sendSubviewToBack(tailView)
    }
}

/// PDF 텍스트 박스를 편집하는 동안 웹 어시스트와 같은 가로 스크롤 도구를 키보드 위에 표시합니다.
final class PortalPDFTextEditorView: UITextView, UIGestureRecognizerDelegate {
    var portalAccessoryView: UIView?
    private lazy var portalCursorTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handlePortalCursorTap(_:)))
        recognizer.numberOfTouchesRequired = 1
        recognizer.numberOfTapsRequired = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addGestureRecognizer(portalCursorTapGesture)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(portalCursorTapGesture)
    }

    override var inputAccessoryView: UIView? {
        get { portalAccessoryView }
        set { portalAccessoryView = newValue }
    }

    @objc private func handlePortalCursorTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              isEditable,
              let position = closestPosition(to: recognizer.location(in: self)),
              let range = textRange(from: position, to: position) else { return }
        selectedTextRange = range
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === portalCursorTapGesture || otherGestureRecognizer === portalCursorTapGesture else {
            return false
        }

        let nativeGesture = gestureRecognizer === portalCursorTapGesture
            ? otherGestureRecognizer
            : gestureRecognizer
        if let nativeTap = nativeGesture as? UITapGestureRecognizer,
           nativeTap.numberOfTapsRequired >= 2 {
            return false
        }
        if nativeGesture is UILongPressGestureRecognizer {
            return false
        }
        return true
    }

    /// UIKit의 단어/문장 선택 제스처가 단일 탭 커서 보정보다 먼저 판정되도록 합니다.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === portalCursorTapGesture else { return false }
        if let nativeTap = otherGestureRecognizer as? UITapGestureRecognizer {
            return nativeTap.numberOfTapsRequired >= 2
        }
        return otherGestureRecognizer is UILongPressGestureRecognizer
    }
}

/// 텍스트 입력기 영역만 터치를 받고 나머지 투명 영역은 PDFView로 통과시킵니다.
/// 페이지 전체 크기의 오버레이가 PDF 이동·확대 제스처를 가로채지 않도록 합니다.
class PortalPDFTextOverlayView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { subview in
            guard subview.isUserInteractionEnabled,
                  !subview.isHidden,
                  subview.alpha > 0.01 else { return false }
            return subview.point(inside: convert(point, to: subview), with: event)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews.reversed() where subview.isUserInteractionEnabled && !subview.isHidden && subview.alpha > 0.01 {
            let convertedPoint = convert(point, to: subview)
            if let hitView = subview.hitTest(convertedPoint, with: event) {
                return hitView
            }
        }
        // 텍스트 입력기 밖의 투명 영역은 PDFView로 통과시킵니다.
        return nil
    }
}

/// 저장용 Ink와 편집 이미지를 PDFKit의 고배율 래스터 Annotation 레이어로 만들지 않고,
/// 벡터 경로와 원본 CGImage 레이어로 그리는 페이지 오버레이입니다.
final class PortalPDFInkOverlayView: PortalPDFTextOverlayView {
    private struct Stroke {
        enum Rendering {
            case stroke(lineWidth: CGFloat, lineCap: CGLineCap, lineJoin: CGLineJoin)
            case fill
        }

        let path: CGPath
        let color: CGColor
        let rendering: Rendering
        let drawingBounds: CGRect
    }

    /// FileManager의 LineLayer처럼 완료 획 벡터와 준비된 비트맵을 함께 보관합니다.
    private final class RasterStrokeLayer: CAShapeLayer {
        let sourcePath: CGPath
        let sourceColor: CGColor
        let sourceRendering: Stroke.Rendering
        var rasterGeneration = 0
        var pendingRasterReadyCallbacks: [() -> Void] = []

        init(stroke: Stroke, localPath: CGPath) {
            sourcePath = localPath
            sourceColor = stroke.color
            sourceRendering = stroke.rendering
            super.init()
        }

        override init(layer: Any) {
            guard let source = layer as? RasterStrokeLayer else {
                fatalError("RasterStrokeLayer requires the same layer type")
            }
            sourcePath = source.sourcePath
            sourceColor = source.sourceColor
            sourceRendering = source.sourceRendering
            rasterGeneration = source.rasterGeneration
            super.init(layer: layer)
        }

        required init?(coder: NSCoder) {
            nil
        }
    }

    private weak var page: PDFPage?
    private weak var pdfView: PDFView?
    /// PDF Annotation 대신 화면에 직접 그릴 페이지별 편집 데이터입니다.
    private var pageEditData: PortalPDFPageEditDocument.Page?
    private var strokes: [Stroke] = []
    private var inkLayers: [RasterStrokeLayer] = []
    private var imageLayers: [CALayer] = []
    private var objectLayers: [CALayer] = []
    private var imagePixelSizes: [CGSize] = []
    private var imageSelectionLayers: [CAShapeLayer] = []
    private var configuredBoundsSize = CGSize.zero
    private var basePageToOverlayTransform: CGAffineTransform?
    private var renderGeneration = 0
    private struct CachedImage {
        let data: Data
        let cgImage: CGImage
    }
    private var decodedImages: [UUID: CachedImage] = [:]
    private struct CachedAnimatedImage {
        let data: Data
        let frames: [CGImage]
        let keyTimes: [NSNumber]
        let duration: CFTimeInterval
    }
    private var decodedAnimatedImages: [UUID: CachedAnimatedImage] = [:]
    private var pendingAnimatedImageIDs: Set<UUID> = []
    /// FileManager의 DrawingView처럼 확대 중에는 이 컨테이너 하나만 transform 합니다.
    private lazy var pageContentLayer: CALayer = {
        let contentLayer = CALayer()
        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        layer.addSublayer(contentLayer)
        return contentLayer
    }()
    /// 선택 UI는 본문과 분리해 객체 변경 없이 독립적으로 갱신합니다.
    private lazy var interactionLayer: CALayer = {
        let interactionLayer = CALayer()
        interactionLayer.anchorPoint = .zero
        interactionLayer.position = .zero
        layer.addSublayer(interactionLayer)
        return interactionLayer
    }()

    var renderedInkStrokeCount: Int {
        strokes.count
    }

    var renderedInkBounds: CGRect {
        strokes.reduce(CGRect.null) { $0.union($1.drawingBounds) }
    }

    var renderedImageCount: Int {
        imageLayers.count
    }

    var renderedImagePixelSizes: [CGSize] {
        imagePixelSizes
    }

    var renderedImageSelectionLayerCount: Int {
        imageSelectionLayers.count
    }

    var renderedAnimatedImageCount: Int {
        imageLayers.filter { $0.animation(forKey: "nf.gif.contents") != nil }.count
    }

    var renderedPageEditObjectLayerCount: Int {
        objectLayers.count
    }

    var pageEditRenderGeneration: Int {
        renderGeneration
    }

    var completedStrokeLayersUseBoundedRasterCache: Bool {
        !inkLayers.isEmpty && inkLayers.allSatisfy {
            ($0.shouldRasterize || $0.contents != nil)
                && $0.frame.width < bounds.width
                && $0.frame.height < bounds.height
        }
    }

    var completedStrokeRasterizationScales: [CGFloat] {
        inkLayers.map(\.rasterizationScale)
    }

    var completedStrokeRasterImageCount: Int {
        inkLayers.filter { $0.contents != nil }.count
    }

    var hiddenCompletedStrokeLayerCount: Int {
        inkLayers.filter(\.isHidden).count
    }

    func configure(
        page: PDFPage,
        pdfView: PDFView,
        pageEditData: PortalPDFPageEditDocument.Page? = nil
    ) {
        self.page = page
        self.pdfView = pdfView
        self.pageEditData = pageEditData
        reloadInkPaths()
    }

    func updatePageEditData(
        _ pageEditData: PortalPDFPageEditDocument.Page?,
        appendedStrokeRasterReady: (() -> Void)? = nil
    ) {
        if let previousPage = self.pageEditData,
           let pageEditData,
           canAppendOnly(previousPage: previousPage, updatedPage: pageEditData) {
            self.pageEditData = pageEditData
            appendLastPageEditObject(
                from: pageEditData,
                rasterReady: appendedStrokeRasterReady
            )
            return
        }
        self.pageEditData = pageEditData
        reloadInkPaths()
        if let appendedStrokeRasterReady {
            DispatchQueue.main.async(execute: appendedStrokeRasterReady)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != configuredBoundsSize else { return }
        configuredBoundsSize = bounds.size
        updateViewportTransform()
    }

    func reloadInkPaths() {
        guard bounds.width > 0,
              bounds.height > 0,
              let page,
              let pdfView else { return }
        configuredBoundsSize = bounds.size
        let pageToOverlay = pageToOverlayTransform(page: page, pdfView: pdfView)
        basePageToOverlayTransform = pageToOverlay
        let pageUnitScale = max(0.0001, hypot(pageToOverlay.a, pageToOverlay.b))
        var updatedStrokes: [Stroke] = []

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureRenderContainer(pageContentLayer)
        configureRenderContainer(interactionLayer)
        pageContentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        interactionLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()

        imageLayers = []
        imagePixelSizes = []
        imageSelectionLayers = []
        objectLayers = []

        if let pageEditData {
            renderPageEditObjects(
                pageEditData.objects.sorted(by: { $0.displayIndex < $1.displayIndex }),
                pageToOverlay: pageToOverlay,
                pageUnitScale: pageUnitScale,
                updatedStrokes: &updatedStrokes
            )
            renderInteractionSelection(
                from: page,
                pageToOverlay: pageToOverlay,
                pageUnitScale: pageUnitScale
            )
        } else {
            renderLegacyAnnotationObjects(
                on: page,
                pageToOverlay: pageToOverlay,
                pageUnitScale: pageUnitScale,
                updatedStrokes: &updatedStrokes
            )
        }

        strokes = updatedStrokes
        inkLayers = updatedStrokes.map { makeStrokeLayer($0) }
        let validImageIDs = Set(pageEditData?.objects.compactMap { $0.kind == .image ? $0.id : nil } ?? [])
        decodedImages = decodedImages.filter { validImageIDs.contains($0.key) }
        decodedAnimatedImages = decodedAnimatedImages.filter { validImageIDs.contains($0.key) }
        pendingAnimatedImageIDs.formIntersection(validImageIDs)
        renderGeneration += 1
    }

    private func configureRenderContainer(_ container: CALayer) {
        container.anchorPoint = .zero
        container.position = .zero
        container.bounds = CGRect(origin: .zero, size: bounds.size)
        container.setAffineTransform(.identity)
    }

    /// Pinch 중에는 기존 필기·이미지 레이어를 다시 만들지 않고 FileManager처럼 행렬만 바꿉니다.
    private func updateViewportTransform() {
        guard let page,
              let pdfView,
              let baseTransform = basePageToOverlayTransform,
              abs(baseTransform.a * baseTransform.d - baseTransform.b * baseTransform.c) > 0.000_001 else {
            return
        }
        let currentTransform = pageToOverlayTransform(page: page, pdfView: pdfView)
        let delta = baseTransform.inverted().concatenating(currentTransform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageContentLayer.setAffineTransform(delta)
        interactionLayer.setAffineTransform(delta)
        CATransaction.commit()
    }

    private func canAppendOnly(
        previousPage: PortalPDFPageEditDocument.Page,
        updatedPage: PortalPDFPageEditDocument.Page
    ) -> Bool {
        let previousObjects = previousPage.objects.sorted { $0.displayIndex < $1.displayIndex }
        let updatedObjects = updatedPage.objects.sorted { $0.displayIndex < $1.displayIndex }
        guard updatedObjects.count == previousObjects.count + 1,
              updatedObjects.last?.kind == .ink || updatedObjects.last?.kind == .pressureInk else {
            return false
        }
        return zip(previousObjects, updatedObjects).allSatisfy { $0.id == $1.id }
    }

    private func appendLastPageEditObject(
        from page: PortalPDFPageEditDocument.Page,
        rasterReady: (() -> Void)?
    ) {
        guard let object = page.objects.max(by: { $0.displayIndex < $1.displayIndex }),
              let pageToOverlay = basePageToOverlayTransform else {
            reloadInkPaths()
            if let rasterReady { DispatchQueue.main.async(execute: rasterReady) }
            return
        }
        let pageUnitScale = max(0.0001, hypot(pageToOverlay.a, pageToOverlay.b))
        var appendedStrokes: [Stroke] = []
        renderPageEditObjects(
            [object],
            pageToOverlay: pageToOverlay,
            pageUnitScale: pageUnitScale,
            updatedStrokes: &appendedStrokes
        )
        strokes.append(contentsOf: appendedStrokes)
        if appendedStrokes.isEmpty {
            if let rasterReady { DispatchQueue.main.async(execute: rasterReady) }
        } else {
            var remainingRasterCount = appendedStrokes.count
            let strokeReady = {
                remainingRasterCount -= 1
                if remainingRasterCount == 0 {
                    rasterReady?()
                }
            }
            inkLayers.append(contentsOf: appendedStrokes.map {
                makeStrokeLayer($0, rasterReady: strokeReady)
            })
        }
        refreshInteractionSelection()
    }

    func refreshInteractionSelection() {
        guard let page,
              let pageToOverlay = basePageToOverlayTransform else { return }
        interactionLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        imageSelectionLayers = []
        renderInteractionSelection(
            from: page,
            pageToOverlay: pageToOverlay,
            pageUnitScale: max(0.0001, hypot(pageToOverlay.a, pageToOverlay.b))
        )
    }

    /// FileManager `StickerItemView`처럼 선택 이미지 하나의 기존 CALayer만 이동·회전·크기 변경합니다.
    /// 페이지의 펜·다른 이미지·텍스트 레이어는 다시 만들지 않습니다.
    func updateImageAnnotationPresentation(_ annotation: PortalPDFImageAnnotation) {
        guard let pageToOverlay = basePageToOverlayTransform,
              let identifier = annotation.value(forAnnotationKey: .name) as? String,
              let imageLayer = imageLayers.first(where: { $0.name == imageLayerName(identifier) }) else {
            reloadInkPaths()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyImageLayerGeometry(
            imageLayer,
            bounds: annotation.imageBounds,
            rotationAngle: annotation.rotationAngle,
            isHorizontallyFlipped: annotation.isHorizontallyFlipped,
            pageToOverlay: pageToOverlay
        )
        CATransaction.commit()
        refreshInteractionSelection()
    }

    private func imageLayerName(_ identifier: String) -> String {
        "nf.image.\(identifier)"
    }

    /// FileManager의 `setLineLayersUpdateScale`처럼 확대가 끝난 뒤에만 완료 획 캐시 해상도를 갱신합니다.
    func refreshCompletedStrokeRasterizationScale() {
        guard let pdfView else { return }
        // FileManager LineLayer는 `UIGraphicsBeginImageContextWithOptions`에
        // `scrollView.zoomScale + OVER_SCALE(5)`를 그대로 사용합니다. PDF 페이지
        // 오버레이 내부 변환 비율은 부모 ScrollView 확대를 반영하지 않으므로 사용하지 않습니다.
        let rasterizationScale = max(1, pdfView.scaleFactor + 5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayers.forEach { layer in
            layer.rasterizationScale = rasterizationScale
            if layer.contents != nil {
                // 기존 이미지는 새 이미지가 준비될 때까지 그대로 확대 표시하고 완료 시 교체합니다.
                rasterizeStrokeLayer(layer, scale: rasterizationScale)
            }
        }
        CATransaction.commit()
    }

    /// 이전 PDF 내부 Annotation은 최초 마이그레이션 시에만 오버레이 데이터 원본으로 사용합니다.
    private func renderLegacyAnnotationObjects(
        on page: PDFPage,
        pageToOverlay: CGAffineTransform,
        pageUnitScale: CGFloat,
        updatedStrokes: inout [Stroke]
    ) {

        for annotation in page.annotations {
            guard PortalPDFInkDisplaySuppression.isSuppressed(annotation),
                  let imageAnnotation = annotation as? PortalPDFImageAnnotation,
                  let cgImage = imageAnnotation.image.cgImage,
                  imageAnnotation.imageBounds.width > 0,
                  imageAnnotation.imageBounds.height > 0 else { continue }

            let imageLayer = makeImageLayer(
                annotation: imageAnnotation,
                cgImage: cgImage,
                pageToOverlay: pageToOverlay
            )
            if let identifier = imageAnnotation.value(forAnnotationKey: .name) as? String {
                imageLayer.name = imageLayerName(identifier)
                if let objectID = UUID(uuidString: identifier) {
                    installAnimatedGIFIfNeeded(
                        imageAnnotation.animatedGIFData,
                        objectID: objectID,
                        on: imageLayer
                    )
                }
            }
            pageContentLayer.addSublayer(imageLayer)
            imageLayers.append(imageLayer)
            imagePixelSizes.append(CGSize(width: cgImage.width, height: cgImage.height))

            if imageAnnotation.isPortalSelected {
                let selectionLayers = makeImageSelectionLayers(
                    annotation: imageAnnotation,
                    pageToOverlay: pageToOverlay
                )
                selectionLayers.forEach { interactionLayer.addSublayer($0) }
                imageSelectionLayers.append(contentsOf: selectionLayers)
            }
        }

        for annotation in page.annotations where PortalPDFInkDisplaySuppression.isSuppressed(annotation) {
            if annotation.isPortalInkAnnotation {
                let lineWidth = max(0.3, annotation.border?.lineWidth ?? 1) * pageUnitScale
                for path in annotation.paths ?? [] {
                    var localToPage = CGAffineTransform(
                        translationX: annotation.bounds.minX,
                        y: annotation.bounds.minY
                    )
                    guard let pagePath = path.cgPath.copy(using: &localToPage) else { continue }
                    var transform = pageToOverlay
                    guard let overlayPath = pagePath.copy(using: &transform) else { continue }
                    let drawingBounds = overlayPath.boundingBoxOfPath.insetBy(
                        dx: -lineWidth,
                        dy: -lineWidth
                    )
                    updatedStrokes.append(Stroke(
                        path: overlayPath,
                        color: annotation.color.cgColor,
                        rendering: .stroke(
                            lineWidth: lineWidth,
                            lineCap: path.lineCapStyle,
                            lineJoin: path.lineJoinStyle
                        ),
                        drawingBounds: drawingBounds
                    ))
                }
                continue
            }

            guard PortalPDFPressureInkAnnotation.isPressureInk(annotation),
                  let stored = PortalPDFPressureInkAnnotation.storedStrokes(in: annotation) else {
                continue
            }
            let color = PortalPDFPressureInkAnnotation.storedColor(in: annotation).cgColor
            for fragment in stored.fragments {
                guard let pagePath = PortalPDFPressureInkAnnotation.makeStrokePath(
                    points: fragment.points,
                    pressures: fragment.pressures,
                    baseLineWidth: stored.baseLineWidth
                ) else { continue }
                var transform = pageToOverlay
                guard let overlayPath = pagePath.cgPath.copy(using: &transform) else { continue }
                updatedStrokes.append(Stroke(
                    path: overlayPath,
                    color: color,
                    rendering: .fill,
                    drawingBounds: overlayPath.boundingBoxOfPath
                ))
            }
        }

    }

    private func makeStrokeLayer(
        _ stroke: Stroke,
        rasterReady: (() -> Void)? = nil
    ) -> RasterStrokeLayer {
            let drawingBounds = stroke.drawingBounds.standardized.integral
            var localTransform = CGAffineTransform(
                translationX: -drawingBounds.minX,
                y: -drawingBounds.minY
            )
            let localPath = stroke.path.copy(using: &localTransform) ?? stroke.path
            let shapeLayer = RasterStrokeLayer(stroke: stroke, localPath: localPath)
            shapeLayer.frame = drawingBounds
            shapeLayer.path = localPath
            shapeLayer.contentsScale = traitCollection.displayScale
            shapeLayer.allowsEdgeAntialiasing = true
            shapeLayer.actions = [
                "contents": NSNull(),
                "hidden": NSNull(),
                "opacity": NSNull(),
                "path": NSNull(),
                "sublayers": NSNull(),
            ]
            // 완료 획은 작은 획 영역 단위로 비트맵 캐시되어 이후 확대·펜 입력에서
            // 기존 벡터 경로를 반복 합성하지 않습니다.
            shapeLayer.shouldRasterize = true
            shapeLayer.rasterizationScale = max(1, (pdfView?.scaleFactor ?? 1) + 5)
            // 신규 완료 획은 백그라운드 비트맵이 준비될 때까지 숨기고 실시간 레이어만 유지합니다.
            // 반투명 하이라이터도 두 레이어가 겹쳐 잠시 진해지지 않습니다.
            shapeLayer.isHidden = rasterReady != nil
            switch stroke.rendering {
            case .stroke(let lineWidth, let lineCap, let lineJoin):
                shapeLayer.fillColor = UIColor.clear.cgColor
                shapeLayer.strokeColor = stroke.color
                shapeLayer.lineWidth = lineWidth
                switch lineCap {
                case .butt: shapeLayer.lineCap = .butt
                case .round: shapeLayer.lineCap = .round
                case .square: shapeLayer.lineCap = .square
                @unknown default: shapeLayer.lineCap = .round
                }
                switch lineJoin {
                case .miter: shapeLayer.lineJoin = .miter
                case .round: shapeLayer.lineJoin = .round
                case .bevel: shapeLayer.lineJoin = .bevel
                @unknown default: shapeLayer.lineJoin = .round
                }
            case .fill:
                shapeLayer.fillColor = stroke.color
                shapeLayer.fillRule = .nonZero
                shapeLayer.strokeColor = UIColor.clear.cgColor
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pageContentLayer.addSublayer(shapeLayer)
            CATransaction.commit()
            if let rasterReady {
                rasterizeStrokeLayer(
                    shapeLayer,
                    scale: shapeLayer.rasterizationScale,
                    completion: rasterReady
                )
            }
            return shapeLayer
    }

    /// FileManager LineLayer.addLine과 동일하게 완료 획 비트맵을 백그라운드에서 준비합니다.
    /// 준비 전에는 실시간 벡터가 계속 보이고, 준비 완료 시 한 트랜잭션에서 이미지로 교체합니다.
    private func rasterizeStrokeLayer(
        _ layer: RasterStrokeLayer,
        scale: CGFloat,
        completion: (() -> Void)? = nil
    ) {
        if let completion {
            layer.pendingRasterReadyCallbacks.append(completion)
        }
        layer.rasterGeneration += 1
        let generation = layer.rasterGeneration
        let size = layer.bounds.size
        let path = layer.sourcePath
        let color = layer.sourceColor
        let rendering = layer.sourceRendering
        guard size.width > 0, size.height > 0 else {
            let callbacks = layer.pendingRasterReadyCallbacks
            layer.pendingRasterReadyCallbacks = []
            layer.isHidden = false
            callbacks.forEach { $0() }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak layer] in
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = scale
            let image = UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
                let context = rendererContext.cgContext
                context.addPath(path)
                switch rendering {
                case .stroke(let lineWidth, let lineCap, let lineJoin):
                    context.setFillColor(UIColor.clear.cgColor)
                    context.setStrokeColor(color)
                    context.setLineWidth(lineWidth)
                    context.setLineCap(lineCap)
                    context.setLineJoin(lineJoin)
                    context.strokePath()
                case .fill:
                    context.setFillColor(color)
                    context.fillPath(using: .winding)
                }
            }
            DispatchQueue.main.async {
                guard let layer,
                      layer.rasterGeneration == generation else { return }
                let callbacks = layer.pendingRasterReadyCallbacks
                layer.pendingRasterReadyCallbacks = []
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.contents = image.cgImage
                layer.contentsScale = scale
                layer.contentsGravity = .resize
                layer.path = nil
                layer.shouldRasterize = false
                layer.rasterizationScale = scale
                layer.isHidden = false
                // 영구 이미지 표시와 Coordinator의 실시간 레이어 제거를 같은 트랜잭션에 넣습니다.
                callbacks.forEach { $0() }
                CATransaction.commit()
            }
        }
    }

    /// 숨은 Annotation 프록시 중 현재 선택된 객체의 조절 UI만 별도 벡터 레이어로 표시합니다.
    private func renderInteractionSelection(
        from page: PDFPage,
        pageToOverlay: CGAffineTransform,
        pageUnitScale: CGFloat
    ) {
        for annotation in page.annotations {
            if let image = annotation as? PortalPDFImageAnnotation, image.isPortalSelected {
                let layers = makeImageSelectionLayers(
                    annotation: image,
                    pageToOverlay: pageToOverlay
                )
                layers.forEach { interactionLayer.addSublayer($0) }
                imageSelectionLayers.append(contentsOf: layers)
                continue
            }

            let selectionBounds: CGRect?
            let rotationAngle: CGFloat
            if let shape = annotation as? PortalPDFShapeAnnotation, shape.isPortalSelected {
                selectionBounds = shape.shapeBounds
                rotationAngle = shape.rotationAngle
            } else if let text = annotation as? PortalPDFTextAnnotation, text.isPortalTextSelected {
                selectionBounds = text.textBounds
                rotationAngle = 0
            } else {
                continue
            }
            guard let selectionBounds else { continue }
            let outline = UIBezierPath(rect: selectionBounds.insetBy(dx: -8, dy: -8))
            if rotationAngle != 0 {
                outline.apply(
                    CGAffineTransform(translationX: selectionBounds.midX, y: selectionBounds.midY)
                        .rotated(by: rotationAngle)
                        .translatedBy(x: -selectionBounds.midX, y: -selectionBounds.midY)
                )
            }
            outline.apply(pageToOverlay)
            let outlineLayer = shapeLayer(path: outline.cgPath)
            outlineLayer.fillColor = UIColor.clear.cgColor
            outlineLayer.strokeColor = UIColor.systemBlue.cgColor
            outlineLayer.lineWidth = max(0.75, pageUnitScale)
            outlineLayer.lineDashPattern = [4, 3]
            interactionLayer.addSublayer(outlineLayer)
            imageSelectionLayers.append(outlineLayer)
        }
    }

    /// `.nfedit` 편집 모델을 PDF 페이지 Annotation으로 변환하지 않고 Core Animation Layer로 직접 표시합니다.
    private func renderPageEditObjects(
        _ objects: [PortalPDFPageEditDocument.Object],
        pageToOverlay: CGAffineTransform,
        pageUnitScale: CGFloat,
        updatedStrokes: inout [Stroke]
    ) {
        for object in objects {
            switch object.kind {
            case .ink:
                guard let ink = object.ink,
                      let color = UIColor.portalColor(rgba: ink.colorRGBA) else { continue }
                let lineWidth = max(0.3, ink.lineWidth) * pageUnitScale
                for savedPath in ink.paths {
                    var transform = pageToOverlay
                    guard let overlayPath = savedPath.uiBezierPath.cgPath.copy(using: &transform) else { continue }
                    updatedStrokes.append(Stroke(
                        path: overlayPath,
                        color: color.cgColor,
                        rendering: .stroke(
                            lineWidth: lineWidth,
                            lineCap: CGLineCap(rawValue: ink.lineCapRawValue) ?? .round,
                            lineJoin: CGLineJoin(rawValue: ink.lineJoinRawValue) ?? .round
                        ),
                        drawingBounds: overlayPath.boundingBoxOfPath.insetBy(
                            dx: -lineWidth,
                            dy: -lineWidth
                        )
                    ))
                }
            case .pressureInk:
                guard let ink = object.ink,
                      let color = UIColor.portalColor(rgba: ink.colorRGBA) else { continue }
                for fragment in ink.pressureFragments {
                    let points = fragment.points.map(\.cgPoint)
                    let pressures = fragment.pressures.map { CGFloat($0) }
                    guard let pagePath = PortalPDFPressureInkAnnotation.makeStrokePath(
                        points: points,
                        pressures: pressures,
                        baseLineWidth: CGFloat(ink.lineWidth)
                    ) else { continue }
                    var transform = pageToOverlay
                    guard let overlayPath = pagePath.cgPath.copy(using: &transform) else { continue }
                    updatedStrokes.append(Stroke(
                        path: overlayPath,
                        color: color.cgColor,
                        rendering: .fill,
                        drawingBounds: overlayPath.boundingBoxOfPath
                    ))
                }
            case .image:
                guard let metadata = object.image,
                      let cgImage = decodedImage(for: object.id, metadata: metadata) else { continue }
                let imageLayer = makeImageLayer(
                    metadata: metadata,
                    cgImage: cgImage,
                    objectID: object.id,
                    pageToOverlay: pageToOverlay
                )
                imageLayer.name = imageLayerName(object.id.uuidString)
                pageContentLayer.addSublayer(imageLayer)
                imageLayers.append(imageLayer)
                imagePixelSizes.append(CGSize(width: cgImage.width, height: cgImage.height))
            case .shape:
                guard let metadata = object.shape,
                      let shapeType = PortalPDFShapeType(rawValue: metadata.shapeType),
                      let lineColor = UIColor.portalColor(rgba: metadata.lineColorRGBA),
                      let fillColor = UIColor.portalColor(rgba: metadata.fillColorRGBA) else { continue }
                let inset = CGFloat(metadata.lineWidth) / 2 + 1
                let shapePath = PortalPDFShapePath.make(
                    shapeType,
                    in: metadata.bounds.insetBy(dx: inset, dy: inset),
                    yAxisPointsDown: false
                )
                let rotation = CGAffineTransform(translationX: metadata.bounds.midX, y: metadata.bounds.midY)
                    .rotated(by: CGFloat(metadata.rotationAngle))
                    .translatedBy(x: -metadata.bounds.midX, y: -metadata.bounds.midY)
                shapePath.apply(rotation)
                var transform = pageToOverlay
                guard let overlayPath = shapePath.cgPath.copy(using: &transform) else { continue }
                let shapeLayer = CAShapeLayer()
                shapeLayer.frame = pageContentLayer.bounds
                shapeLayer.path = overlayPath
                shapeLayer.fillColor = fillColor.cgColor
                shapeLayer.strokeColor = lineColor.cgColor
                shapeLayer.lineWidth = CGFloat(metadata.lineWidth) * pageUnitScale
                shapeLayer.lineCap = .round
                shapeLayer.lineJoin = .round
                shapeLayer.contentsScale = traitCollection.displayScale
                pageContentLayer.addSublayer(shapeLayer)
                objectLayers.append(shapeLayer)
            case .text:
                guard let metadata = object.text else { continue }
                let textLayer = makeTextLayer(metadata: metadata, pageToOverlay: pageToOverlay)
                pageContentLayer.addSublayer(textLayer)
                objectLayers.append(textLayer)
            }
        }
    }

    /// 같은 이미지 객체는 최초 한 번만 디코딩하고 확대·필기 갱신에서는 CGImage를 재사용합니다.
    private func decodedImage(
        for objectID: UUID,
        metadata: PortalPDFImageAnnotation.Metadata
    ) -> CGImage? {
        if let cached = decodedImages[objectID], cached.data == metadata.imageData {
            return cached.cgImage
        }
        guard let image = UIImage(data: metadata.imageData), let cgImage = image.cgImage else { return nil }
        decodedImages[objectID] = CachedImage(data: metadata.imageData, cgImage: cgImage)
        return cgImage
    }

    private func makeImageLayer(
        metadata: PortalPDFImageAnnotation.Metadata,
        cgImage: CGImage,
        objectID: UUID,
        pageToOverlay: CGAffineTransform
    ) -> CALayer {
        let imageLayer = CALayer()
        imageLayer.name = imageLayerName(objectID.uuidString)
        imageLayer.contents = cgImage
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.allowsEdgeAntialiasing = true
        applyImageLayerGeometry(
            imageLayer,
            bounds: metadata.bounds,
            rotationAngle: CGFloat(metadata.rotationAngle),
            isHorizontallyFlipped: metadata.isHorizontallyFlipped,
            pageToOverlay: pageToOverlay
        )
        installAnimatedGIFIfNeeded(metadata.animatedGIFData, objectID: objectID, on: imageLayer)
        return imageLayer
    }

    /// FileManager `StickerItemView`의 `animationImages`처럼 GIF 프레임을 한 번 디코딩해
    /// 기존 이미지 CALayer의 contents 애니메이션으로 재생합니다.
    private func installAnimatedGIFIfNeeded(
        _ data: Data?,
        objectID: UUID,
        on imageLayer: CALayer
    ) {
        guard let data else { return }
        if let cached = decodedAnimatedImages[objectID], cached.data == data {
            applyAnimatedImage(cached, to: imageLayer)
            return
        }
        guard pendingAnimatedImageIDs.insert(objectID).inserted else { return }
        let expectedLayerName = imageLayer.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let decoded = Self.decodeAnimatedImage(data) else {
                DispatchQueue.main.async { self?.pendingAnimatedImageIDs.remove(objectID) }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingAnimatedImageIDs.remove(objectID)
                self.decodedAnimatedImages[objectID] = decoded
                guard let currentLayer = self.imageLayers.first(where: {
                    $0.superlayer != nil && $0.name == expectedLayerName
                }) else { return }
                self.applyAnimatedImage(decoded, to: currentLayer)
            }
        }
    }

    nonisolated private static func decodeAnimatedImage(_ data: Data) -> CachedAnimatedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return nil }
        var frames: [CGImage] = []
        var delays: [Double] = []
        frames.reserveCapacity(frameCount)
        delays.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            guard let frame = CGImageSourceCreateImageAtIndex(
                source,
                index,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            ) else { continue }
            frames.append(frame)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
            delays.append(max(0.02, unclamped ?? clamped ?? 0.1))
        }
        guard frames.count > 1, frames.count == delays.count else { return nil }
        let duration = delays.reduce(0, +)
        guard duration > 0 else { return nil }
        var elapsed = 0.0
        let keyTimes = delays.map { delay -> NSNumber in
            defer { elapsed += delay }
            return NSNumber(value: elapsed / duration)
        }
        return CachedAnimatedImage(
            data: data,
            frames: frames,
            keyTimes: keyTimes,
            duration: duration
        )
    }

    private func applyAnimatedImage(_ animatedImage: CachedAnimatedImage, to imageLayer: CALayer) {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = animatedImage.frames
        animation.keyTimes = animatedImage.keyTimes
        animation.duration = animatedImage.duration
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        imageLayer.add(animation, forKey: "nf.gif.contents")
    }

    private func applyImageLayerGeometry(
        _ imageLayer: CALayer,
        bounds imageBounds: CGRect,
        rotationAngle: CGFloat,
        isHorizontallyFlipped: Bool,
        pageToOverlay: CGAffineTransform
    ) {
        let center = CGPoint(x: imageBounds.midX, y: imageBounds.midY).applying(pageToOverlay)
        let cosine = cos(rotationAngle)
        let sine = sin(rotationAngle)
        let horizontalDirection: CGFloat = isHorizontallyFlipped ? -1 : 1
        let pageXAxis = CGPoint(x: horizontalDirection * cosine, y: horizontalDirection * sine)
        let pageYAxis = CGPoint(x: sine, y: -cosine)
        let overlayXAxis = pageXAxis.applyingLinearPart(of: pageToOverlay)
        let overlayYAxis = pageYAxis.applyingLinearPart(of: pageToOverlay)
        imageLayer.bounds = CGRect(origin: .zero, size: imageBounds.size)
        imageLayer.position = center
        imageLayer.setAffineTransform(CGAffineTransform(
            a: overlayXAxis.x,
            b: overlayXAxis.y,
            c: overlayYAxis.x,
            d: overlayYAxis.y,
            tx: 0,
            ty: 0
        ))
    }

    private func makeTextLayer(
        metadata: PortalPDFTextAnnotation.Metadata,
        pageToOverlay: CGAffineTransform
    ) -> CALayer {
        let container = CALayer()
        container.bounds = CGRect(origin: .zero, size: metadata.bounds.size)
        container.position = CGPoint(x: metadata.bounds.midX, y: metadata.bounds.midY).applying(pageToOverlay)
        container.backgroundColor = UIColor.portalColor(rgba: metadata.fillColorRGBA)?.cgColor
        container.borderColor = UIColor.portalColor(rgba: metadata.borderColorRGBA)?.cgColor
        container.borderWidth = 1

        let xAxis = CGPoint(x: 1, y: 0).applyingLinearPart(of: pageToOverlay)
        let yAxis = CGPoint(x: 0, y: -1).applyingLinearPart(of: pageToOverlay)
        container.setAffineTransform(CGAffineTransform(
            a: xAxis.x,
            b: xAxis.y,
            c: yAxis.x,
            d: yAxis.y,
            tx: 0,
            ty: 0
        ))

        let textLayer = CATextLayer()
        textLayer.frame = container.bounds.insetBy(dx: 5, dy: 4)
        textLayer.contentsScale = traitCollection.displayScale
        textLayer.isWrapped = true
        textLayer.truncationMode = .end
        textLayer.alignmentMode = switch metadata.alignmentRawValue {
        case NSTextAlignment.center.rawValue: .center
        case NSTextAlignment.right.rawValue: .right
        default: .left
        }
        let fontSize = CGFloat(metadata.fontSize)
        let baseFont = UIFont(name: metadata.fontName, size: fontSize)
            ?? .systemFont(ofSize: fontSize)
        var symbolicTraits = baseFont.fontDescriptor.symbolicTraits
        if metadata.isBold { symbolicTraits.insert(.traitBold) }
        if metadata.isItalic { symbolicTraits.insert(.traitItalic) }
        let fontDescriptor = baseFont.fontDescriptor.withSymbolicTraits(symbolicTraits)
            ?? baseFont.fontDescriptor
        let font = UIFont(descriptor: fontDescriptor, size: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = NSTextAlignment(rawValue: metadata.alignmentRawValue) ?? .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.portalColor(rgba: metadata.textColorRGBA) ?? .black,
            .paragraphStyle: paragraphStyle,
            .underlineStyle: metadata.isUnderlined ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: metadata.isStruckThrough ? NSUnderlineStyle.single.rawValue : 0,
        ]
        if let rtf = metadata.attributedTextRTF,
           let attributedText = try? NSAttributedString(
               data: rtf,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ),
           attributedText.string == metadata.text {
            textLayer.string = attributedText
        } else {
            textLayer.string = NSAttributedString(string: metadata.text, attributes: attributes)
        }
        container.addSublayer(textLayer)
        return container
    }

    /// 이미지 픽셀을 확대 배율 크기의 새 비트맵으로 만들지 않고 원본 CGImage 하나를 재사용합니다.
    private func makeImageLayer(
        annotation: PortalPDFImageAnnotation,
        cgImage: CGImage,
        pageToOverlay: CGAffineTransform
    ) -> CALayer {
        let imageBounds = annotation.imageBounds
        let center = CGPoint(x: imageBounds.midX, y: imageBounds.midY).applying(pageToOverlay)
        let angle = annotation.rotationAngle
        let cosine = cos(angle)
        let sine = sin(angle)
        let horizontalDirection: CGFloat = annotation.isHorizontallyFlipped ? -1 : 1

        // CALayer의 로컬 Y축은 아래쪽이 양수이므로 PDF 페이지의 -Y축을 이미지 아래쪽으로 매핑합니다.
        // 이 보정으로 기존 PDFAnnotation 렌더링과 같은 상·하 방향을 유지합니다.
        let pageXAxis = CGPoint(x: horizontalDirection * cosine, y: horizontalDirection * sine)
        let pageYAxis = CGPoint(x: sine, y: -cosine)
        let overlayXAxis = pageXAxis.applyingLinearPart(of: pageToOverlay)
        let overlayYAxis = pageYAxis.applyingLinearPart(of: pageToOverlay)

        let imageLayer = CALayer()
        imageLayer.bounds = CGRect(origin: .zero, size: imageBounds.size)
        imageLayer.position = center
        imageLayer.contents = cgImage
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.allowsEdgeAntialiasing = true
        imageLayer.setAffineTransform(CGAffineTransform(
            a: overlayXAxis.x,
            b: overlayXAxis.y,
            c: overlayYAxis.x,
            d: overlayYAxis.y,
            tx: 0,
            ty: 0
        ))
        return imageLayer
    }

    /// 선택선과 조절점은 작은 벡터 경로로 분리해 1000%에서도 이미지 크기의 backing store를 만들지 않습니다.
    private func makeImageSelectionLayers(
        annotation: PortalPDFImageAnnotation,
        pageToOverlay: CGAffineTransform
    ) -> [CAShapeLayer] {
        let annotationToOverlay = rotatedPageToOverlayTransform(
            center: annotation.imageBounds.center,
            angle: annotation.rotationAngle,
            pageToOverlay: pageToOverlay
        )
        let unitScale = max(0.0001, hypot(pageToOverlay.a, pageToOverlay.b))
        let selectionScale = max(annotation.selectionDisplayScaleFactor, 0.1)
        var layers: [CAShapeLayer] = []

        let outlineInset = 1.5 / selectionScale
        let outlinePath = UIBezierPath(rect: annotation.annotationOutlineRect.insetBy(
            dx: outlineInset,
            dy: outlineInset
        ))
        outlinePath.apply(annotationToOverlay)
        let outlineLayer = shapeLayer(path: outlinePath.cgPath)
        outlineLayer.fillColor = UIColor.clear.cgColor
        outlineLayer.strokeColor = UIColor.systemBlue.cgColor
        outlineLayer.lineWidth = max(0.5, annotation.displayedSelectionLineWidth * unitScale)
        outlineLayer.lineDashPattern = annotation.displayedSelectionDashLengths.map {
            NSNumber(value: Double($0 * unitScale))
        }
        layers.append(outlineLayer)

        let resizePath = UIBezierPath()
        let resizeSide = annotation.displayedResizeHandleSide
        for center in annotation.unrotatedResizeHandleCenters.values {
            resizePath.append(UIBezierPath(rect: CGRect(
                x: center.x - resizeSide / 2,
                y: center.y - resizeSide / 2,
                width: resizeSide,
                height: resizeSide
            )))
        }
        resizePath.apply(annotationToOverlay)
        let resizeLayer = shapeLayer(path: resizePath.cgPath)
        resizeLayer.fillColor = UIColor.white.cgColor
        resizeLayer.strokeColor = UIColor.black.cgColor
        resizeLayer.lineWidth = max(0.5, annotation.displayedSelectionLineWidth * unitScale)
        layers.append(resizeLayer)

        layers.append(contentsOf: makeImageActionHandleLayers(
            annotation: annotation,
            annotationToOverlay: annotationToOverlay,
            unitScale: unitScale
        ))
        return layers
    }

    private func makeImageActionHandleLayers(
        annotation: PortalPDFImageAnnotation,
        annotationToOverlay: CGAffineTransform,
        unitScale: CGFloat
    ) -> [CAShapeLayer] {
        var layers: [CAShapeLayer] = []

        func addHandle(
            center: CGPoint,
            diameter: CGFloat,
            fillColor: UIColor,
            icon: UIBezierPath,
            iconLineWidth: CGFloat
        ) {
            let circle = UIBezierPath(ovalIn: CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
            circle.apply(annotationToOverlay)
            let circleLayer = shapeLayer(path: circle.cgPath)
            circleLayer.fillColor = fillColor.cgColor
            circleLayer.strokeColor = UIColor.white.cgColor
            circleLayer.lineWidth = max(0.7, 0.9 / annotation.editingDisplayScaleFactor * unitScale)
            layers.append(circleLayer)

            icon.apply(annotationToOverlay)
            let iconLayer = shapeLayer(path: icon.cgPath)
            iconLayer.fillColor = UIColor.clear.cgColor
            iconLayer.strokeColor = UIColor.white.cgColor
            iconLayer.lineWidth = max(1, iconLineWidth * unitScale)
            iconLayer.lineCap = .round
            iconLayer.lineJoin = .round
            layers.append(iconLayer)
        }

        let deleteCenter = annotation.unrotatedDeleteHandleCenter
        let deleteDiameter = annotation.displayedDeleteHandleDiameter
        let deleteInset = 7 / annotation.editingDisplayScaleFactor
        let deleteRect = CGRect(
            x: deleteCenter.x - deleteDiameter / 2,
            y: deleteCenter.y - deleteDiameter / 2,
            width: deleteDiameter,
            height: deleteDiameter
        )
        let deleteIcon = UIBezierPath()
        deleteIcon.move(to: CGPoint(x: deleteRect.minX + deleteInset, y: deleteRect.minY + deleteInset))
        deleteIcon.addLine(to: CGPoint(x: deleteRect.maxX - deleteInset, y: deleteRect.maxY - deleteInset))
        deleteIcon.move(to: CGPoint(x: deleteRect.maxX - deleteInset, y: deleteRect.minY + deleteInset))
        deleteIcon.addLine(to: CGPoint(x: deleteRect.minX + deleteInset, y: deleteRect.maxY - deleteInset))
        addHandle(
            center: deleteCenter,
            diameter: deleteDiameter,
            fillColor: .systemRed,
            icon: deleteIcon,
            iconLineWidth: 2 / annotation.editingDisplayScaleFactor
        )

        let transformCenter = annotation.unrotatedTransformHandleCenter
        let transformDiameter = annotation.displayedTransformHandleDiameter
        let transformRect = CGRect(
            x: transformCenter.x - transformDiameter / 2,
            y: transformCenter.y - transformDiameter / 2,
            width: transformDiameter,
            height: transformDiameter
        )
        let iconInset = 7 / annotation.editingDisplayScaleFactor
        let arrowHeadLength = 4 / annotation.editingDisplayScaleFactor
        let lowerLeft = CGPoint(x: transformRect.minX + iconInset, y: transformRect.minY + iconInset)
        let upperRight = CGPoint(x: transformRect.maxX - iconInset, y: transformRect.maxY - iconInset)
        let transformIcon = UIBezierPath()
        transformIcon.move(to: lowerLeft)
        transformIcon.addLine(to: upperRight)
        transformIcon.move(to: CGPoint(x: upperRight.x - arrowHeadLength, y: upperRight.y))
        transformIcon.addLine(to: upperRight)
        transformIcon.addLine(to: CGPoint(x: upperRight.x, y: upperRight.y - arrowHeadLength))
        transformIcon.move(to: CGPoint(x: lowerLeft.x + arrowHeadLength, y: lowerLeft.y))
        transformIcon.addLine(to: lowerLeft)
        transformIcon.addLine(to: CGPoint(x: lowerLeft.x, y: lowerLeft.y + arrowHeadLength))
        addHandle(
            center: transformCenter,
            diameter: transformDiameter,
            fillColor: .systemBlue,
            icon: transformIcon,
            iconLineWidth: 1.8 / annotation.editingDisplayScaleFactor
        )
        return layers
    }

    private func shapeLayer(path: CGPath) -> CAShapeLayer {
        let shapeLayer = CAShapeLayer()
        shapeLayer.frame = interactionLayer.bounds
        shapeLayer.path = path
        shapeLayer.contentsScale = traitCollection.displayScale
        shapeLayer.allowsEdgeAntialiasing = true
        return shapeLayer
    }

    private func rotatedPageToOverlayTransform(
        center: CGPoint,
        angle: CGFloat,
        pageToOverlay: CGAffineTransform
    ) -> CGAffineTransform {
        let cosine = cos(angle)
        let sine = sin(angle)
        let a = pageToOverlay.a * cosine + pageToOverlay.c * sine
        let b = pageToOverlay.b * cosine + pageToOverlay.d * sine
        let c = -pageToOverlay.a * sine + pageToOverlay.c * cosine
        let d = -pageToOverlay.b * sine + pageToOverlay.d * cosine
        let mappedCenter = center.applying(pageToOverlay)
        return CGAffineTransform(
            a: a,
            b: b,
            c: c,
            d: d,
            tx: mappedCenter.x - a * center.x - c * center.y,
            ty: mappedCenter.y - b * center.x - d * center.y
        )
    }

    private func pageToOverlayTransform(page: PDFPage, pdfView: PDFView) -> CGAffineTransform {
        let origin = convert(pdfView.convert(CGPoint.zero, from: page), from: pdfView)
        let xAxis = convert(pdfView.convert(CGPoint(x: 1, y: 0), from: page), from: pdfView)
        let yAxis = convert(pdfView.convert(CGPoint(x: 0, y: 1), from: page), from: pdfView)
        return CGAffineTransform(
            a: xAxis.x - origin.x,
            b: xAxis.y - origin.y,
            c: yAxis.x - origin.x,
            d: yAxis.y - origin.y,
            tx: origin.x,
            ty: origin.y
        )
    }
}

private extension CGPoint {
    func applyingLinearPart(of transform: CGAffineTransform) -> CGPoint {
        CGPoint(
            x: transform.a * x + transform.c * y,
            y: transform.b * x + transform.d * y
        )
    }
}

private extension UIView {
    /// PDFView 내부 문서·스크롤 계층에 등록된 제스처를 빠짐없이 반환합니다.
    var portalDescendantGestureRecognizers: [UIGestureRecognizer] {
        (gestureRecognizers ?? []) + subviews.flatMap(\.portalDescendantGestureRecognizers)
    }
}

// MARK: - PDF Annotation Gesture Coordinator 입니다.
extension PortalPDFKitView {
    /**
     PDFView 위에서 펜, 지우개, 박스 주석 제스처를 처리하는 Coordinator 입니다. ( J.D.H )
     - Version: 1.0.0
     - Date: 2026.07.30
     */
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UITextViewDelegate, UIFontPickerViewControllerDelegate, PDFPageOverlayViewProvider, UIPencilInteractionDelegate {
        enum AnnotationHistoryRecord {
            case retained(PDFAnnotation)
            case image(PortalPDFImageAnnotation.HistoryState)
            case shape(bounds: CGRect, contents: String)
            case text(bounds: CGRect, contents: String)
            case pressure(
                fragments: [PortalPDFPressureInkAnnotation.StrokeFragment],
                lineWidth: CGFloat,
                color: UIColor
            )
            case ink(
                bounds: CGRect,
                paths: [CGPath],
                color: UIColor,
                lineWidth: CGFloat,
                contents: String?,
                userName: String?
            )
        }

        final class AnnotationHistorySnapshot {
            let documentID: ObjectIdentifier
            let pageAnnotations: [[AnnotationHistoryRecord]]

            init(documentID: ObjectIdentifier, pageAnnotations: [[AnnotationHistoryRecord]]) {
                self.documentID = documentID
                self.pageAnnotations = pageAnnotations
            }
        }

        /// PDF 파일에는 저장하지 않고 페이지 오버레이에만 표시하는 네온 한 획입니다.
        final class TransientNeonStroke {
            weak var page: PDFPage?
            let pagePoints: [CGPoint]
            let color: UIColor
            let lineWidth: CGFloat
            var layers: [CAShapeLayer] = []

            init(page: PDFPage, pagePoints: [CGPoint], color: UIColor, lineWidth: CGFloat) {
                self.page = page
                self.pagePoints = pagePoints
                self.color = color
                self.lineWidth = lineWidth
            }
        }

        /// PDFView에 마지막으로 반영한 SwiftUI 입력값입니다.
        /// 이동 중 동일한 입력이 반복되면 updateUIView의 무거운 PDFKit 갱신을 건너뜁니다.
        var lastRenderState: RenderState?
        /// 스크롤 감속이 끝난 뒤 최종 위치를 한 번 저장하는 작업입니다.
        var viewportSaveWorkItem: DispatchWorkItem?
        /// PDFView 내부 ScrollView 이동 제스처입니다.
        weak var viewportPanGesture: UIPanGestureRecognizer?
        /// PDFView 내부 ScrollView 확대 제스처입니다.
        weak var viewportPinchGesture: UIPinchGestureRecognizer?
        /// 앱 비활성화 직전 마지막 위치를 즉시 확정하기 위한 Notification Observer입니다.
        var viewportLifecycleObserver: NSObjectProtocol?
        /// 백그라운드 복귀 후 PDFKit이 문서 레이아웃을 초기화한 경우 위치를 다시 복원하는 Observer입니다.
        var viewportActivationObserver: NSObjectProtocol?
        /// iOS 메모리 압박 시 전체 경로를 보관하는 오래된 Undo 스냅샷을 해제하는 Observer입니다.
        var memoryWarningObserver: NSObjectProtocol?
        /// 고배율 PDFKit 타일이 누적됐을 때 렌더 캐시만 교체하는 지연 작업입니다.
        var renderCacheTrimWorkItem: DispatchWorkItem?
        /// 현재 문서를 연결한 직후의 프로세스 메모리 기준값입니다.
        var pdfRenderingMemoryBaseline: UInt64 = 0
        /// PDFKit 문서 재연결 중 제스처·메모리 경고가 중복 진입하지 않게 합니다.
        var isRecyclingPDFRenderingCache = false
        /// 실기기 스트레스 검증에서 렌더 캐시 회수 동작 여부를 확인하는 누적 횟수입니다.
        private(set) var renderCacheRecycleCount = 0
        /// 연속 확대·이동 중 문서 뷰 재생성이 반복되어 끊기지 않도록 마지막 회수 시각을 보관합니다.
        var lastRenderCacheRecycleTime: CFTimeInterval = 0
        /// 현재 PDF의 확대·위치 저장 식별자입니다.
        var viewportPersistenceIdentifier: String?
        /// 같은 PDFDocument에 저장 위치를 반복 적용하지 않도록 보관합니다.
        var restoredViewportDocumentID: ObjectIdentifier?
        /// 같은 PDFDocument 객체가 다른 저장 키로 사용될 때 복원이 누락되지 않도록 보관합니다.
        var restoredViewportIdentifier: String?
        /// 저장 위치 적용 중 제스처 종료 저장을 막습니다.
        var isRestoringViewport = false
        /// 백그라운드 전환 직전에 현재 화면 위치를 이미 저장했는지 나타냅니다.
        /// SwiftUI dismantle 단계에서 편집 종료 후 변경된 중앙 위치가 기존 값을 덮어쓰지 않게 합니다.
        var didPersistViewportForBackgroundTransition = false

        /// PDFView 갱신 여부를 판단하기 위한 최소 입력 스냅샷입니다.
        struct RenderState: Equatable {
            let documentID: ObjectIdentifier
            let selectedTool: PortalPDFMarkupTool
            let penColorComponents: [CGFloat]
            let penLineWidth: CGFloat
            let penType: PortalPDFPenType
            let penPressureStrength: CGFloat
            let penStrokeSmoothingStrength: CGFloat
            let highlighterCap: PortalPDFHighlighterCap
            let shapeType: PortalPDFShapeType
            let shapeLineColorComponents: [CGFloat]
            let shapeFillColorComponents: [CGFloat]
            let textBorderColorComponents: [CGFloat]
            let textFillColorComponents: [CGFloat]
            let textColorComponents: [CGFloat]
            let pendingImageID: UUID?
            let pendingImageEditCommandID: UUID?
            let pendingShapeID: UUID?
            let pendingTextID: UUID?
        }

        /// 현재 PDFView에 적용할 편집 도구입니다.
        var selectedTool: PortalPDFMarkupTool = .view
        /// 펜 도구로 PDF 주석을 추가할 때 사용할 현재 색상입니다.
        var penColor: UIColor = .systemBlue
        /// 펜 도구로 PDF 주석을 추가할 때 사용할 PDF Page 좌표계 기준 굵기입니다.
        var penLineWidth: CGFloat = 2.4
        /// 펜 도구의 굵기 적용 방식입니다.
        var penType: PortalPDFPenType = .fixed
        /// 압력 타입에서 센서 압력에 따른 굵기 변화량입니다.
        var penPressureStrength: CGFloat = 1.0
        /// 펜 스트로크의 끝 삐침을 완화할 현재 강도입니다.
        var penStrokeSmoothingStrength: CGFloat = 0.5
        /// 형광펜 시작·끝 부분의 표시 방식입니다.
        var highlighterCap: PortalPDFHighlighterCap = .round
        /// 지우개가 적용되는 화면 기준 지름입니다.
        var eraserSize: CGFloat = 24
        /// 지우개 상세창이 열린 동안 마지막 지우개 위치에 미리보기를 표시할지 여부입니다.
        var isEraserPreviewVisible = false
        /// 마지막으로 지우개가 위치했던 PDFView 화면 좌표입니다.
        var lastEraserViewPoint: CGPoint?
        /// 박스 도구로 PDF에 추가할 현재 도형 종류입니다.
        var selectedShapeType: PortalPDFShapeType = .rectangle
        /// 박스 도구로 PDF에 추가할 도형 선 색상입니다.
        var shapeLineColor: UIColor = .systemOrange
        /// 박스 도구로 PDF에 추가할 도형 배경 색상입니다.
        var shapeFillColor: UIColor = .systemOrange.withAlphaComponent(0.14)
        /// 제스처가 연결된 PDFView 입니다.
        weak var pdfView: PDFView?
        /// 마지막으로 PDFView에 반영한 이미지 삽입 요청 식별자입니다.
        var lastInsertedImageID: UUID?
        /// 마지막으로 PDFView에 반영한 이미지 편집 명령 식별자입니다.
        var lastAppliedImageEditCommandID: UUID?
        /// 마지막으로 PDFView에 반영한 도형 삽입 요청 식별자입니다.
        var lastInsertedShapeID: UUID?
        /// 마지막으로 PDFView에 반영한 텍스트 박스 삽입 요청 식별자입니다.
        var lastInsertedTextID: UUID?
        /// 현재 선택되어 확대/축소/회전 편집 대상이 된 이미지 Annotation 입니다.
        weak var selectedImageAnnotation: PortalPDFImageAnnotation?
        /// 현재 선택되어 이동/확대/축소/회전 편집 대상이 된 도형 Annotation 입니다.
        weak var selectedShapeAnnotation: PortalPDFShapeAnnotation?
        /// 현재 키보드와 어시스트 바에서 편집 중인 텍스트 Annotation 입니다.
        weak var selectedTextAnnotation: PortalPDFTextAnnotation?
        /// PDF 위에 겹쳐 표시하는 실제 텍스트 입력기입니다.
        weak var activeTextEditor: PortalPDFTextEditorView?
        /// PDF 주석의 폰트 단위를 현재 화면 배율로 변환할 때 사용한 마지막 배율입니다.
        var activeTextEditorDisplayScale: CGFloat = 1
        /// 시스템 폰트 선택기가 포커스를 가져가는 동안 텍스트 편집 종료를 보류합니다.
        var isPresentingTextFontPicker = false
        var textFontPickerSelection: NSRange?
        struct SuspendedPDFGestureState {
            let recognizer: UIGestureRecognizer
            let wasEnabled: Bool
            let minimumTouches: Int?
            let maximumTouches: Int?
        }

        /// 텍스트 편집 중 조정한 PDFView 제스처의 원래 활성화·터치 전달 상태입니다.
        var suspendedPDFGestureStates: [SuspendedPDFGestureState] = []
        /// 텍스트 편집 중 PDF 이동으로 키보드가 내려가지 않도록 보관하는 원래 설정입니다.
        weak var textEditingDocumentScrollView: UIScrollView?
        var suspendedKeyboardDismissMode: UIScrollView.KeyboardDismissMode?
        var suspendedScrollDelaysContentTouches: Bool?
        /// PDFKit이 실제 PDF 페이지 위에 배치한 페이지별 입력 오버레이입니다.
        /// 텍스트 편집기는 최상위 PDFView가 아니라 이 컨테이너에만 추가합니다.
        var pageOverlayViews: [ObjectIdentifier: UIView] = [:]
        /// 저장용 Ink를 현재 PDFKit 문서에서 한 번만 숨기기 위한 문서 식별자입니다.
        var persistentInkOverlayDocumentID: ObjectIdentifier?
        /// PDF 본문과 분리해 저장하고 화면 오버레이가 직접 사용하는 페이지 편집 문서입니다.
        var pageEditDocument = PortalPDFPageEditDocument()
        /// 현재 편집 문서를 저장할 안정적인 문서 식별자입니다.
        var pageEditPersistenceIdentifier: String?
        /// 연속 필기 중 매 획마다 이미지 데이터까지 직렬화하지 않도록 마지막 변경 뒤 저장을 합칩니다.
        var pageEditSaveWorkItem: DispatchWorkItem?
        /// 동일 PDFDocument에 편집 데이터를 중복 복원하지 않기 위한 식별자입니다.
        var pageEditPersistenceDocumentID: ObjectIdentifier?
        let pageEditRepository = PortalPDFPageEditRepository()
        /// PDFKit 페이지 렌더 계층과 분리된 실제 UITextView 터치 전용 호스트입니다.
        weak var textEditingHostView: PortalPDFTextOverlayView?
        /// 선택 텍스트 박스 위의 말풍선 작업 메뉴를 올리는 최상위 터치 호스트입니다.
        weak var textActionMenuHostView: PortalPDFTextOverlayView?
        /// 현재 표시 중인 텍스트 박스 작업 메뉴입니다.
        weak var textActionMenuView: PortalPDFTextActionMenuView?
        /// 작업 메뉴가 연결된 텍스트 Annotation입니다.
        weak var textActionMenuAnnotation: PortalPDFTextAnnotation?
        /// 선택 이미지 위의 말풍선 작업 메뉴를 올리는 최상위 터치 호스트입니다.
        weak var imageActionMenuHostView: PortalPDFTextOverlayView?
        /// 현재 표시 중인 이미지 편집 말풍선 메뉴입니다.
        weak var imageActionMenuView: PortalPDFImageActionMenuView?
        /// 이미지 작업 메뉴가 연결된 Annotation입니다.
        weak var imageActionMenuAnnotation: PortalPDFImageAnnotation?
        /// 키보드가 표시될 때 현재 텍스트 박스를 가리지 않도록 PDFView 위치를 보정합니다.
        var textKeyboardObserver: NSObjectProtocol?
        /// resignFirstResponder 콜백과 명시적 종료가 중복 실행되지 않도록 보호합니다.
        var isFinishingTextEditing = false
        /// 이미지 주석 길게 누름으로 편집 모드 진입 시 SwiftUI 상태를 변경하는 이벤트입니다.
        var onActivateImageTool: () -> Void = {}
        /// 도형 주석 길게 누름으로 편집 모드 진입 시 SwiftUI 상태를 변경하는 이벤트입니다.
        var onActivateShapeTool: () -> Void = {}
        /// 텍스트 박스 선택으로 편집 모드 진입 시 SwiftUI 상태를 변경하는 이벤트입니다.
        var onActivateTextTool: () -> Void = {}
        /// 이미지 말풍선 메뉴의 선택 기능을 SwiftUI에 전달하는 이벤트입니다.
        var onImageActionRequested: (PortalPDFImageAction) -> Void = { _ in }
        /// 펜 드로잉 시작 시 SwiftUI 컬러 편집 상태를 기본 모드로 되돌리는 이벤트입니다.
        var onBeginPenDrawing: () -> Void = {}
        /// Apple Pencil 이중 탭 시 SwiftUI 편집 도구를 전환하는 이벤트입니다.
        var onPencilDoubleTap: () -> Void = {}
        /// 세 손가락 스와이프로 프레젠테이션 상단 제어 UI를 표시하는 이벤트입니다.
        var onPresentationControlsReveal: () -> Void = {}
        /// 현재 페이지 변경을 SwiftUI 전체 페이지 팝업에 전달하는 이벤트입니다.
        var onCurrentPageChanged: (Int) -> Void = { _ in }
        /// 현재 PDF 확대 배율을 정수 퍼센트로 SwiftUI에 전달하는 이벤트입니다.
        var onZoomPercentageChanged: (Int) -> Void = { _ in }
        /// PDFKit 페이지 변경 Notification 관찰자입니다.
        var pageChangedObserver: NSObjectProtocol?
        /// 자동 맞춤·핀치·저장 배율 복원을 모두 감지하는 PDFKit 배율 변경 관찰자입니다.
        var scaleChangedObserver: NSObjectProtocol?
        /// 같은 페이지 번호를 SwiftUI에 반복 전달하지 않도록 마지막 값을 보관합니다.
        var lastReportedCurrentPageIndex: Int?
        /// 핀치 이벤트가 발생해도 같은 정수 퍼센트는 반복 전달하지 않습니다.
        var lastReportedZoomPercentage: Int?
        /// 연속 배율 알림을 한 프레임의 최신 값으로 합치기 위한 대기 값입니다.
        var pendingZoomPercentage: Int?
        /// 1000% 왕복 중 SwiftUI 갱신이 큐에 누적되지 않도록 최대 30fps로 제한합니다.
        var zoomPercentageReportWorkItem: DispatchWorkItem?
        /// 현재 획을 저장한 뒤 이중 탭 도구 전환을 실행해야 하는지 나타냅니다.
        var hasPendingPencilDoubleTap = false
        /// PDFView에 연결된 Apple Pencil 외부 동작 Interaction입니다.
        var pencilInteraction: UIPencilInteraction?
        /// 이미지 Annotation 선택 여부를 SwiftUI에 전달하는 이벤트입니다.
        var onImageSelectionChanged: (Bool) -> Void = { _ in }
        /// 선택 이미지의 시스템 Markup 편집 요청을 SwiftUI에 전달하는 이벤트입니다.
        var onSystemImageEditRequested: (UIImage) -> Void = { _ in }
        /// 선택 이미지의 전용 자르기 화면 표시 요청을 SwiftUI에 전달하는 이벤트입니다.
        var onImageCropRequested: (UIImage) -> Void = { _ in }
        /// 동일한 이미지 선택 상태를 반복 전달하지 않도록 마지막 값을 보관합니다.
        var lastReportedImageSelectionState: Bool?
        /// 도형 Annotation 선택 여부를 SwiftUI에 전달하는 이벤트입니다.
        var onShapeSelectionChanged: (Bool) -> Void = { _ in }
        /// PDF 편집 변경을 SwiftUI 자동 저장 흐름에 전달하는 이벤트입니다.
        var documentChangedHandler: () -> Void = {}
        /// 실행 취소·다시 실행 버튼 활성 상태를 SwiftUI에 전달합니다.
        var onHistoryAvailabilityChanged: (Bool, Bool) -> Void = { _, _ in }
        var currentHistorySnapshot: AnnotationHistorySnapshot?
        var undoHistorySnapshots: [AnnotationHistorySnapshot] = []
        var redoHistorySnapshots: [AnnotationHistorySnapshot] = []
        var historyDocumentID: ObjectIdentifier?
        var lastAppliedHistoryCommandID: UUID?
        /// 마지막으로 PDFView에 반영한 페이지 추가·복제 명령 식별자입니다.
        var lastAppliedPageEditCommandID: UUID?
        /// 마지막으로 PDFView에 반영한 페이지 이동 명령 식별자입니다.
        var lastAppliedPageNavigationCommandID: UUID?
        /// 마지막으로 PDFView에 반영한 페이지 구조 갱신 명령 식별자입니다.
        var lastAppliedPageStructureRefreshCommandID: UUID?
        var isApplyingHistory = false
        var lastReportedHistoryAvailability: (canUndo: Bool, canRedo: Bool)?
        /// 동일한 도형 선택 상태를 반복 전달하지 않도록 마지막 값을 보관합니다.
        var lastReportedShapeSelectionState: Bool?
        /// 이미지/도형 롱프레스가 펜·지우개 팬보다 먼저 편집 대상을 확인하도록 사용하는 Gesture 입니다.
        weak var imageLongPressGesture: UILongPressGestureRecognizer?
        /// 이미지 롱프레스보다 늦게 시작해야 하는 PDFView 기본 제스처 식별자입니다.
        var prioritizedPDFGestureIDs: Set<ObjectIdentifier> = []
        /// 이미지 롱프레스가 편집용 한 손가락 동작보다 먼저 대상 확인을 하도록 보관합니다.
        weak var drawingPanGesture: UIPanGestureRecognizer?
        /// 확정된 올가미 영역 밖을 한 번 누르면 선택을 즉시 해제하는 Gesture입니다.
        weak var lassoTapGesture: UITapGestureRecognizer?
        /// PDFKit Pan과 분리해 터치 시작부터 좌표를 전달하는 지우개 전용 Gesture입니다.
        weak var eraserDrawingGesture: PortalPDFEraserGestureRecognizer?
        /// 이동 임계값 없이 짧은 획과 coalesced touch를 모두 받는 펜 전용 Gesture 입니다.
        weak var penDrawingGesture: PortalPDFPenGestureRecognizer?
        /// 이미지 편집 모드에서 한 번의 선택으로 편집 대상을 활성화하는 Gesture 입니다.
        weak var imageTapGesture: UITapGestureRecognizer?
        /// 선택 이미지의 왼쪽 상단 삭제 버튼을 다른 PDF 제스처보다 먼저 처리하는 Gesture 입니다.
        weak var imageDeleteTapGesture: UITapGestureRecognizer?
        /// 도형 편집 모드에서 한 번의 선택으로 편집 대상을 활성화하는 Gesture 입니다.
        weak var shapeTapGesture: UITapGestureRecognizer?
        /// 텍스트 모드에서 기존 텍스트를 편집하거나 새 입력 박스를 추가하는 Gesture 입니다.
        weak var textTapGesture: UITapGestureRecognizer?
        /// 이미지·박스·텍스트에 손이 닿는 순간 객체 타입 선택과 편집 도구 자동 전환을 처리합니다.
        weak var textTouchDownGesture: PortalPDFTextTouchDownGestureRecognizer?
        /// 선택 텍스트의 왼쪽 상단 삭제 버튼을 다른 PDF 제스처보다 먼저 처리하는 Gesture 입니다.
        weak var textDeleteTapGesture: UITapGestureRecognizer?
        /// 활성화된 텍스트 박스를 길게 눌러 실제 문자 편집을 시작하는 Gesture 입니다.
        weak var textLongPressGesture: UILongPressGestureRecognizer?
        /// 이미지 회전 변경 전용 Rotation Gesture 입니다.
        weak var imageRotationGesture: UIRotationGestureRecognizer?
        /// 프레젠테이션 제어 UI를 표시하는 세 손가락 위 스와이프입니다.
        weak var presentationSwipeUpGesture: UISwipeGestureRecognizer?
        /// 프레젠테이션 제어 UI를 표시하는 세 손가락 아래 스와이프입니다.
        weak var presentationSwipeDownGesture: UISwipeGestureRecognizer?
        /// 편집 모드에서 일시 중지한 PDFKit 기본 텍스트 선택·더블탭 제스처입니다.
        let editingDisabledDocumentGestures = NSHashTable<UIGestureRecognizer>.weakObjects()
        /// 이미지 이동 또는 오른쪽 상단 핸들 변형 제스처의 현재 상태입니다.
        var activeImageDragState: ImageDragState?
        /// 펜 도구에서 현재 그리고 있는 PDF Page 입니다.
        weak var activePenPage: PDFPage?
        /// 펜 도구에서 PDF 저장용으로 누적하는 Page 좌표계 기준 자유선 경로입니다.
        var activePenPath: UIBezierPath?
        /// 압력 반응 펜을 선분별 annotation으로 저장하기 위한 Page 좌표 목록입니다.
        var activePenPagePoints: [CGPoint] = []
        /// 압력 반응 펜을 그리는 동안 화면에 동일한 굵기 변화를 표시하기 위한 PDFView 좌표 목록입니다.
        var activePenViewPoints: [CGPoint] = []
        /// 압력 반응 펜을 선분별 annotation으로 저장하기 위한 정규화 압력 목록입니다.
        var activePenPressures: [CGFloat] = []
        /// 펜 도구에서 화면 실시간 표시용으로 누적하는 PDFView 좌표계 기준 자유선 경로입니다.
        var activePenOverlayPath: UIBezierPath?
        /// 중복 좌표를 걸러내고 짧은 획을 판별하기 위한 마지막 PDFView 터치 위치입니다.
        var activePenLastViewPoint: CGPoint?
        /// 탭과 매우 짧은 한글 획도 점으로 저장하기 위한 현재 획의 샘플 수입니다.
        var activePenSampleCount: Int = 0
        /// FileManager `PencilView.newLineDrawing`과 같은 3점 단위 Cubic 보간 상태입니다.
        /// 매 입력마다 전체 좌표를 다시 스무딩하지 않고 새 곡선 조각만 누적합니다.
        var activePenPageCurvePoints = [CGPoint](repeating: .zero, count: 4)
        var activePenViewCurvePoints = [CGPoint](repeating: .zero, count: 4)
        var activePenCurveIndex = 0
        /// 펜 도구 드래그 중 깜빡임 없이 표시하기 위해 PDFView 위에 올리는 임시 Shape Layer 입니다.
        var activePenOverlayLayer: CAShapeLayer?
        /// 압력 반응 펜의 전체 획을 하나의 연속 외곽선으로 표시하는 임시 Shape Layer 입니다.
        var activePressureOverlayLayer: CAShapeLayer?
        /// 터치 이벤트보다 느린 화면 주기에 맞춰 무거운 보정 경로 생성을 한 번으로 묶습니다.
        var activePenOverlayDisplayLink: CADisplayLink?
        /// 다음 화면 프레임에 실시간 보정 경로를 다시 만들어야 하는지 나타냅니다.
        var activePenOverlayNeedsRefresh = false
        /// 네온 펜으로 확정한 획입니다. PDF Annotation에 넣지 않아 저장·공유 파일에는 포함되지 않습니다.
        var transientNeonStrokes: [TransientNeonStroke] = []
        /// 마지막 네온 입력이 끝난 뒤 10초가 지나면 모든 네온 획을 지우는 작업입니다.
        var neonClearWorkItem: DispatchWorkItem?
        /// 지우개가 실제로 적용되는 범위를 표시하는 원형 가이드 Layer 입니다.
        var activeEraserOverlayLayer: CAShapeLayer?
        /// 지우개 드래그 중 이벤트 사이를 연결하기 위한 직전 PDF Page 좌표입니다.
        var activeEraserLastPoint: CGPoint?
        /// 페이지가 바뀌는 순간 이전 페이지 좌표를 새 페이지에 재사용하지 않도록 보관합니다.
        weak var activeEraserPage: PDFPage?
        /// 현재 지우개 드래그에서 실제 PDF Annotation이 변경되었는지 보관합니다.
        var activeEraserDidMutate = false
        /// 지우개 드래그 중 변경된 압력 주석입니다. 메타데이터 직렬화는 손을 뗄 때 한 번만 수행합니다.
        var activeEraserPressureAnnotations: [PortalPDFPressureInkAnnotation] = []
        /// 연속 터치 좌표의 무거운 PDF 경로 계산을 지우개 원 이동과 분리해 묶는 작업입니다.
        var eraserProcessingWorkItem: DispatchWorkItem?
        /// 다음 지우개 처리 프레임에 함께 계산할 페이지 경로 구간입니다.
        var pendingEraserSegments: [EraserSegment] = []
        /// 박스 도구에서 드래그를 시작한 PDF Page 입니다.
        weak var activeBoxPage: PDFPage?
        /// 박스 도구에서 드래그를 시작한 PDF Page 좌표입니다.
        var activeBoxStartPoint: CGPoint?
        /// 박스 도구에서 드래그를 시작한 PDFView 좌표입니다.
        var activeBoxStartViewPoint: CGPoint?
        /// 박스 도구 드래그 중 깜빡임 없이 표시하기 위해 PDFView 위에 올리는 임시 Shape Layer 입니다.
        var activeBoxOverlayLayer: CAShapeLayer?
        /// 올가미로 자유형 선택 영역을 그리고 선택 결과를 표시하는 화면 Overlay입니다.
        var lassoOverlayLayer: CAShapeLayer?
        /// 올가미 선택 영역 양쪽 상단에 표시하는 삭제·변형 조작점 Layer입니다.
        var lassoDeleteHandleLayer: CAShapeLayer?
        var lassoDeleteIconLayer: CAShapeLayer?
        var lassoTransformHandleLayer: CAShapeLayer?
        var lassoTransformIconLayer: CAShapeLayer?
        /// 현재 올가미를 그리고 있는 PDF Page입니다.
        weak var activeLassoPage: PDFPage?
        /// 자유형 올가미의 PDF Page 좌표 목록입니다.
        var activeLassoPoints: [CGPoint] = []
        /// 올가미로 선택된 편집 가능한 Annotation 목록입니다.
        var selectedLassoAnnotations: [PDFAnnotation] = []
        /// 선택된 Annotation 전체를 감싸는 PDF Page 좌표 영역입니다.
        var selectedLassoBounds: CGRect?
        /// 선택 확정 시 사용자가 그린 실제 올가미 외곽선의 PDF Page 좌표입니다.
        var selectedLassoOutlinePoints: [CGPoint] = []
        /// 올가미 선택 프레임이 현재 회전한 각도입니다.
        var selectedLassoRotation: CGFloat = 0
        /// 선택 영역 이동 중 직전 PDF Page 좌표입니다.
        var activeLassoMovePoint: CGPoint?
        /// 현재 올가미 드래그가 선택 영역 작성인지 선택 결과 이동인지 구분합니다.
        var isMovingLassoSelection = false
        /// 현재 올가미 이동에서 실제 변경이 발생했는지 보관합니다.
        var activeLassoDidMove = false
        /// 오른쪽 상단 조작점으로 그룹 변형 중인 직전 거리와 각도입니다.
        var activeLassoTransformState: (distance: CGFloat, angle: CGFloat)?

        /// PDF 편집 도구에서 공통으로 사용하는 수치 값입니다.
        enum DrawingMetrics {
            /// PDF Page 좌표계에서 저장되는 박스 기준 굵기입니다.
            static let boxPDFLineWidth: CGFloat = 2.0
            /// 지우개가 얇은 펜 라인도 잡을 수 있도록 화면 좌표 기준으로 확장하는 선택 반경입니다.
            static let eraserScreenHitRadius: CGFloat = 24.0
        }

        /// 선택 이미지에 대한 한 손가락 드래그 동작입니다.
        enum ImageDragState {
            /// 이미지 본문을 이동하며 직전 PDF Page 좌표를 저장합니다.
            case moving(previousPoint: CGPoint)
            /// 오른쪽 상단 핸들로 크기와 회전을 변경하며 직전 거리와 각도를 저장합니다.
            case transforming(previousDistance: CGFloat, previousAngle: CGFloat)
            /// 이미지·박스·텍스트의 조절점을 드래그할 때 시작 영역과 시작 좌표를 보관합니다.
            case resizingBounds(
                handle: PortalPDFResizeHandle,
                initialBounds: CGRect,
                initialPoint: CGPoint
            )
        }

        struct EraserSegment {
            let page: PDFPage
            let start: CGPoint
            let end: CGPoint
        }

        deinit {
            viewportSaveWorkItem?.cancel()
            renderCacheTrimWorkItem?.cancel()
            zoomPercentageReportWorkItem?.cancel()
            eraserProcessingWorkItem?.cancel()
            neonClearWorkItem?.cancel()
            activePenOverlayDisplayLink?.invalidate()
            pageEditSaveWorkItem?.cancel()
            if let viewportLifecycleObserver {
                NotificationCenter.default.removeObserver(viewportLifecycleObserver)
            }
            if let memoryWarningObserver {
                NotificationCenter.default.removeObserver(memoryWarningObserver)
            }
        }

        /// PDFKit이 각 PDF 페이지에 직접 배치할 투명 오버레이를 제공합니다.
        /// 편집 중이 아닐 때는 PDFView의 이동·확대 제스처를 가로채지 않습니다.
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            let pageID = ObjectIdentifier(page)
            if let existing = pageOverlayViews[pageID] {
                return existing
            }
            let overlay = PortalPDFInkOverlayView(frame: .zero)
            overlay.backgroundColor = .clear
            overlay.isUserInteractionEnabled = false
            pageOverlayViews[pageID] = overlay
            DispatchQueue.main.async { [weak self, weak overlay, weak view, weak page] in
                guard let self, let overlay, let view, let page else { return }
                let pageIndex = view.document?.index(for: page) ?? NSNotFound
                overlay.configure(
                    page: page,
                    pdfView: view,
                    pageEditData: pageIndex == NSNotFound
                        ? nil
                        : self.pageEditDocument.page(at: pageIndex)
                )
                self.renderTransientNeonStrokes(on: page, in: overlay, pdfView: view)
            }
            return overlay
        }

        /// 페이지가 화면에서 내려가면 해당 페이지의 임시 편집기와 오버레이 참조를 정리합니다.
        func pdfView(
            _ pdfView: PDFView,
            willEndDisplayingOverlayView overlayView: UIView,
            for page: PDFPage
        ) {
            if activeTextEditor?.superview === overlayView {
                finishTextEditing()
            }
            let pageID = ObjectIdentifier(page)
            if pageOverlayViews[pageID] === overlayView {
                pageOverlayViews.removeValue(forKey: pageID)
            }
            transientNeonStrokes
                .filter { $0.page === page }
                .forEach { stroke in
                    stroke.layers.forEach { $0.removeFromSuperlayer() }
                    stroke.layers = []
                }
        }

        /// 새 문서를 PDFView에 연결하기 전에 저장용 Ink의 PDFKit 표시를 끄고
        /// 페이지 오버레이가 같은 경로를 타일 단위로 그리도록 준비합니다.
        func activatePersistentInkOverlay(for document: PDFDocument, in pdfView: PDFView) {
            let documentID = ObjectIdentifier(document)
            guard persistentInkOverlayDocumentID != documentID else { return }
            if let previousDocument = pdfView.document, previousDocument !== document {
                PortalPDFInkDisplaySuppression.restore(in: previousDocument)
            }
            PortalPDFInkDisplaySuppression.suppress(in: document)
            persistentInkOverlayDocumentID = documentID
            pdfRenderingMemoryBaseline = PortalPDFProcessMemory.residentBytes()
        }

        /// 기존 PDF Annotation을 한 번만 페이지 편집 파일로 마이그레이션하고,
        /// 이후에는 `.nfedit` 문서를 정본으로 사용해 숨은 상호작용 프록시를 구성합니다.
        func configurePageEditPersistence(identifier: String, document: PDFDocument) {
            let documentID = ObjectIdentifier(document)
            guard pageEditPersistenceIdentifier != identifier
                    || pageEditPersistenceDocumentID != documentID else { return }

            pageEditPersistenceIdentifier = identifier
            pageEditPersistenceDocumentID = documentID
            if let savedDocument = pageEditRepository.load(identifier: identifier),
               savedDocument.formatVersion == PortalPDFPageEditDocument.currentFormatVersion {
                pageEditDocument = savedDocument
                savedDocument.installInteractionProxies(in: document)
            } else {
                pageEditDocument = PortalPDFPageEditDocument.capture(from: document)
                if pageEditDocument.hasEditableObjects {
                    try? pageEditRepository.save(pageEditDocument, identifier: identifier)
                }
            }
            PortalPDFPageEditDocument.suppressManagedAnnotations(in: document)
        }

        /// 메모리의 편집 정본을 원자적으로 저장합니다. 연속 입력은 마지막 변경 한 번으로 합칩니다.
        func persistPageEditDocument() {
            pageEditSaveWorkItem?.cancel()
            pageEditSaveWorkItem = nil
            guard let identifier = pageEditPersistenceIdentifier else { return }
            do {
                try pageEditRepository.save(pageEditDocument, identifier: identifier)
            } catch {
                NSLog("PortalPDF page edit save error: %@", error.localizedDescription)
            }
        }

        func schedulePageEditPersistence() {
            pageEditSaveWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.persistPageEditDocument()
            }
            pageEditSaveWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
        }

        /// 변경된 페이지의 호환 프록시만 정본에 반영해 다른 페이지와 이미지 데이터 순회를 피합니다.
        func updatePageEditDocument(on page: PDFPage) -> PortalPDFPageEditDocument.Page? {
            guard let document = pdfView?.document else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return nil }
            pageEditDocument.updatePage(at: pageIndex, from: document)
            PortalPDFPageEditDocument.suppressManagedAnnotations(on: page)
            return pageEditDocument.page(at: pageIndex)
        }

        /// 새 펜 획 하나는 페이지 전체 재캡처 없이 정본과 화면 레이어 끝에 바로 추가합니다.
        func appendPageEditAnnotation(
            _ annotation: PDFAnnotation,
            on page: PDFPage,
            strokeRasterReady: (() -> Void)? = nil
        ) -> Bool {
            guard let document = pdfView?.document,
                  annotation.page === page else { return false }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound,
                  let displayIndex = page.annotations.firstIndex(where: { $0 === annotation }),
                  pageEditDocument.append(
                      annotation: annotation,
                      at: displayIndex,
                      to: pageIndex
                  ) else { return false }
            PortalPDFPageEditDocument.suppressManagedAnnotations(on: page)
            if let overlay = pageOverlayViews[ObjectIdentifier(page)] as? PortalPDFInkOverlayView {
                overlay.updatePageEditData(
                    pageEditDocument.page(at: pageIndex),
                    appendedStrokeRasterReady: strokeRasterReady
                )
            } else if let strokeRasterReady {
                DispatchQueue.main.async(execute: strokeRasterReady)
            }
            return true
        }

        /// 필기 추가·지우기·Undo 뒤 새 Annotation을 숨기고 표시 중인 페이지 타일만 갱신합니다.
        func refreshPersistentInkOverlays() {
            guard let pdfView, let document = pdfView.document else { return }
            pageEditDocument = PortalPDFPageEditDocument.capture(from: document)
            PortalPDFInkDisplaySuppression.suppress(in: document)
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex),
                      let overlay = pageOverlayViews[ObjectIdentifier(page)] as? PortalPDFInkOverlayView else {
                    continue
                }
                overlay.updatePageEditData(pageEditDocument.page(at: pageIndex))
            }
        }

        /// 이동·회전·크기 변경 중인 한 페이지의 이미지 오버레이만 즉시 갱신합니다.
        func refreshPersistentAnnotationOverlay(on page: PDFPage) {
            (pageOverlayViews[ObjectIdentifier(page)] as? PortalPDFInkOverlayView)?.updatePageEditData(
                updatePageEditDocument(on: page)
            )
        }

        /// 이미지 제스처 중에는 선택 객체의 기존 레이어만 갱신해 페이지 전체 재캡처·재구성을 피합니다.
        func refreshImageAnnotationPresentation(
            _ annotation: PortalPDFImageAnnotation,
            on page: PDFPage
        ) {
            (pageOverlayViews[ObjectIdentifier(page)] as? PortalPDFInkOverlayView)?
                .updateImageAnnotationPresentation(annotation)
        }

        /// PDFView 최상단에 UITextView 터치 전용 호스트를 생성합니다.
        /// 입력기 위치는 PDF Page 좌표에서 계속 변환하므로 확대·이동 후에도 주석 위치를 유지합니다.
        func textEditorContainer(for page: PDFPage, in pdfView: PDFView) -> UIView? {
            if let textEditingHostView, textEditingHostView.superview === pdfView {
                textEditingHostView.frame = pdfView.bounds
                textEditingHostView.isUserInteractionEnabled = true
                pdfView.bringSubviewToFront(textEditingHostView)
                return textEditingHostView
            }
            let hostView = PortalPDFTextOverlayView(frame: pdfView.bounds)
            hostView.backgroundColor = .clear
            hostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hostView.isUserInteractionEnabled = true
            hostView.clipsToBounds = true
            pdfView.addSubview(hostView)
            pdfView.bringSubviewToFront(hostView)
            textEditingHostView = hostView
            return hostView
        }

        /// 현재 문서의 저장 키를 설정하고 PDF 레이아웃이 준비된 뒤 마지막 확대·위치를 복원합니다.
        func configureViewportPersistence(
            identifier: String,
            document: PDFDocument,
            in pdfView: PDFView
        ) {
            // makeUIView 시점에는 문서 내부 확대 ScrollView가 아직 생성되지 않을 수 있습니다.
            // document 연결이 끝난 현재 시점에 실제 문서 ScrollView로 관찰 대상을 다시 맞춥니다.
            observeViewportChanges(in: pdfView)
            configureHistoryIfNeeded(for: document)
            viewportPersistenceIdentifier = identifier
            let documentID = ObjectIdentifier(document)
            guard restoredViewportDocumentID != documentID || restoredViewportIdentifier != identifier else { return }
            restoredViewportDocumentID = documentID
            restoredViewportIdentifier = identifier
            guard let record = PortalPDFViewportStore.load(for: identifier) else { return }
            restoreViewport(record, document: document, in: pdfView)
        }

        /// 저장된 페이지 좌표를 기준으로 PDF 위치를 복원합니다.
        /// 이전 버전 데이터에는 페이지 좌표가 없으므로 기존 ScrollView 오프셋 방식으로 복원합니다.
        func restoreViewport(
            _ record: PortalPDFViewportStore.Record,
            document: PDFDocument,
            in pdfView: PDFView,
            schedulesStabilization: Bool = true
        ) {
            // 앱 복귀 직후에는 PDFKit이 첫 복원 이후 문서 레이아웃을 한 번 더 계산하며
            // contentOffset을 초기화할 수 있습니다. 최초 복원과 별개로 레이아웃이 안정된 뒤
            // 같은 PDF 페이지 좌표를 한 번 더 적용해 백그라운드 전 위치를 유지합니다.
            if schedulesStabilization {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak pdfView] in
                    guard let self, let pdfView, pdfView.document === document else { return }
                    self.restoreViewport(
                        record,
                        document: document,
                        in: pdfView,
                        schedulesStabilization: false
                    )
                }
            }
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView, pdfView.document === document else { return }
                self.isRestoringViewport = true
                let restorePhase = schedulesStabilization ? "initial" : "stabilized"
                pdfView.layoutDocumentView()
                pdfView.layoutIfNeeded()
                let minimumScale = max(pdfView.minScaleFactor, 0.1)
                let maximumScale = max(minimumScale, pdfView.maxScaleFactor)
                let restoredScale = min(max(CGFloat(record.scaleFactor), minimumScale), maximumScale)
                // 저장 위치를 복원하는 동안 PDFKit의 자동 맞춤이 확대 비율과 스크롤 위치를
                // 다시 중앙으로 변경하지 못하게 합니다.
                pdfView.autoScales = false
                pdfView.scaleFactor = restoredScale
                pdfView.layoutDocumentView()
                pdfView.layoutIfNeeded()

                // PDFKit의 문서 레이아웃 원점은 뷰 재생성 시 달라질 수 있으므로 저장된
                // contentOffset만 복원하면 같은 오프셋에서도 전혀 다른 PDF 좌표가 표시됩니다.
                // 저장 당시 화면 중앙의 페이지 좌표를 다시 화면 중앙에 맞추는 방식을 우선합니다.
                var expectedContentOffset: CGPoint?
                if let pageIndex = record.pageIndex,
                   pageIndex >= 0,
                   pageIndex < document.pageCount,
                   let page = document.page(at: pageIndex),
                   let pagePointX = record.pagePointX,
                   let pagePointY = record.pagePointY,
                   pagePointX.isFinite,
                   pagePointY.isFinite {
                    expectedContentOffset = self.restorePageAnchor(
                        CGPoint(x: pagePointX, y: pagePointY),
                        on: page,
                        in: pdfView
                    )
                } else if let scrollView = self.viewportScrollView(in: pdfView),
                          record.contentOffsetX.isFinite,
                          record.contentOffsetY.isFinite {
                    // 페이지 좌표가 저장되지 않은 이전 버전 데이터만 오프셋으로 복원합니다.
                    let offset = self.clampedContentOffset(
                        CGPoint(x: record.contentOffsetX, y: record.contentOffsetY),
                        in: scrollView
                    )
                    expectedContentOffset = offset
                    scrollView.setContentOffset(offset, animated: false)
                    scrollView.layoutIfNeeded()
                }
                // 위치 복원 중 PDFKit이 내부 ScrollView 또는 Pan Gesture를 다시 만들 수 있습니다.
                // 현재 편집 도구의 한 손가락/두 손가락 규칙을 새 인스턴스에 다시 연결해
                // 텍스트 박스 드래그가 PDF 화면 이동으로 바뀌지 않게 합니다.
                self.observeViewportChanges(in: pdfView)
                self.configureDocumentScrollGestures(in: pdfView)
                self.logViewportComparison(
                    record,
                    expectedContentOffset: expectedContentOffset,
                    stage: "\(restorePhase).applied",
                    in: pdfView
                )
                DispatchQueue.main.async { [weak self, weak pdfView] in
                    guard let self, let pdfView, pdfView.document === document else { return }
                    pdfView.layoutIfNeeded()
                    self.observeViewportChanges(in: pdfView)
                    self.configureDocumentScrollGestures(in: pdfView)
                    self.logViewportComparison(
                        record,
                        expectedContentOffset: expectedContentOffset,
                        stage: "\(restorePhase).displayed",
                        in: pdfView
                    )
                }
                self.isRestoringViewport = false
            }
        }

        /// 저장 당시 화면 중앙에 있던 PDF 페이지 좌표를 현재 화면 중앙에 다시 배치합니다.
        /// `PDFView.convert` 결과는 현재 스크롤 위치를 포함하므로, 현재 오프셋에 중심점 차이를
        /// 더하는 방식으로 이동해야 PDFKit의 가변 문서 레이아웃 원점과 무관하게 복원됩니다.
        func restorePageAnchor(
            _ pagePoint: CGPoint,
            on page: PDFPage,
            in pdfView: PDFView
        ) -> CGPoint? {
            guard let scrollView = viewportScrollView(in: pdfView),
                  pdfView.bounds.width > 0,
                  pdfView.bounds.height > 0 else { return nil }

            // 재진입 직후 ScrollView의 contentSize가 이전 문서 레이아웃 기준으로 남아 있으면
            // 저장 좌표까지 필요한 오프셋이 현재 스크롤 범위 밖으로 잘려 버립니다. 먼저
            // PDFKit 자체 목적지 이동으로 저장 페이지 좌표를 유효한 문서 영역에 올린 뒤
            // 화면 중심과의 차이를 보정합니다.
            let destination = PDFDestination(page: page, at: pagePoint)
            destination.zoom = pdfView.scaleFactor
            pdfView.go(to: destination)
            pdfView.layoutDocumentView()
            pdfView.layoutIfNeeded()
            scrollView.layoutIfNeeded()

            let viewportCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            var pagePointInView = pdfView.convert(pagePoint, from: page)
            var targetOffset = clampedContentOffset(
                CGPoint(
                    x: scrollView.contentOffset.x + pagePointInView.x - viewportCenter.x,
                    y: scrollView.contentOffset.y + pagePointInView.y - viewportCenter.y
                ),
                in: scrollView
            )
            scrollView.setContentOffset(targetOffset, animated: false)
            scrollView.layoutIfNeeded()
            pdfView.layoutIfNeeded()

            // 첫 이동으로 PDFKit 내부 타일/문서 원점이 갱신될 수 있어 남은 차이를 한 번 보정합니다.
            pagePointInView = pdfView.convert(pagePoint, from: page)
            let correctionX = pagePointInView.x - viewportCenter.x
            let correctionY = pagePointInView.y - viewportCenter.y
            if abs(correctionX) > 0.5 || abs(correctionY) > 0.5 {
                targetOffset = clampedContentOffset(
                    CGPoint(
                        x: scrollView.contentOffset.x + correctionX,
                        y: scrollView.contentOffset.y + correctionY
                    ),
                    in: scrollView
                )
                scrollView.setContentOffset(targetOffset, animated: false)
                scrollView.layoutIfNeeded()
                pdfView.layoutIfNeeded()
            }
            return targetOffset
        }

        /// 저장된 뷰포트와 PDFView가 실제 화면에 표시한 위치를 Xcode 콘솔에서 비교합니다.
        func logViewportComparison(
            _ record: PortalPDFViewportStore.Record,
            expectedContentOffset: CGPoint?,
            stage: String,
            in pdfView: PDFView
        ) {
            guard let scrollView = viewportScrollView(in: pdfView) else {
                print("[PDFViewport][\(stage)] scrollView=missing")
                return
            }
            let savedOffset = CGPoint(x: record.contentOffsetX, y: record.contentOffsetY)
            let expectedOffset = expectedContentOffset ?? savedOffset
            let actualOffset = scrollView.contentOffset
            let viewportCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            let actualPage = pdfView.page(for: viewportCenter, nearest: true)
            let actualPageIndex = actualPage.flatMap { pdfView.document?.index(for: $0) }
            let actualPagePoint = actualPage.map { pdfView.convert(viewportCenter, to: $0) }
            let hasSavedPageAnchor = record.pageIndex != nil &&
                record.pagePointX != nil &&
                record.pagePointY != nil
            let pageMatches = !hasSavedPageAnchor || actualPageIndex == record.pageIndex
            let pagePointMatches: Bool
            if let savedX = record.pagePointX,
               let savedY = record.pagePointY,
               let actualPagePoint {
                pagePointMatches = abs(actualPagePoint.x - savedX) <= 1 &&
                    abs(actualPagePoint.y - savedY) <= 1
            } else {
                pagePointMatches = !hasSavedPageAnchor
            }
            let offsetMatches = abs(actualOffset.x - expectedOffset.x) <= 1 &&
                abs(actualOffset.y - expectedOffset.y) <= 1
            let positionMatches = hasSavedPageAnchor
                ? pageMatches && pagePointMatches
                : offsetMatches
            let scaleMatches = abs(pdfView.scaleFactor - CGFloat(record.scaleFactor)) <= 0.01
            print(
                String(
                    format: "[PDFViewport][%@] saved=(%.2f, %.2f) expected=(%.2f, %.2f) actual=(%.2f, %.2f) savedScale=%.4f actualScale=%.4f positionMatches=%@ offsetMatches=%@ scaleMatches=%@ savedPage=%@ actualPage=%@ savedPoint=(%@, %@) actualPoint=(%@, %@)",
                    stage,
                    savedOffset.x,
                    savedOffset.y,
                    expectedOffset.x,
                    expectedOffset.y,
                    actualOffset.x,
                    actualOffset.y,
                    record.scaleFactor,
                    pdfView.scaleFactor,
                    positionMatches ? "true" : "false",
                    offsetMatches ? "true" : "false",
                    scaleMatches ? "true" : "false",
                    record.pageIndex.map(String.init) ?? "nil",
                    actualPageIndex.map(String.init) ?? "nil",
                    record.pagePointX.map { String(format: "%.2f", $0) } ?? "nil",
                    record.pagePointY.map { String(format: "%.2f", $0) } ?? "nil",
                    actualPagePoint.map { String(format: "%.2f", $0.x) } ?? "nil",
                    actualPagePoint.map { String(format: "%.2f", $0.y) } ?? "nil"
                )
            )
        }

        /// 확대·스크롤의 모든 프레임을 관찰하지 않고 제스처가 끝나는 시점만 연결합니다.
        func observeViewportChanges(in pdfView: PDFView) {
            guard let scrollView = viewportScrollView(in: pdfView) else { return }
            let panGesture = scrollView.panGestureRecognizer
            let pinchGesture = scrollView.pinchGestureRecognizer
            if viewportPanGesture !== panGesture || viewportPinchGesture !== pinchGesture {
                viewportPanGesture?.removeTarget(self, action: #selector(handleViewportGestureEnded(_:)))
                viewportPinchGesture?.removeTarget(self, action: #selector(handleViewportGestureEnded(_:)))
                panGesture.addTarget(self, action: #selector(handleViewportGestureEnded(_:)))
                pinchGesture?.addTarget(self, action: #selector(handleViewportGestureEnded(_:)))
                viewportPanGesture = panGesture
                viewportPinchGesture = pinchGesture
            }
            if viewportLifecycleObserver == nil {
                viewportLifecycleObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.willResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    // 화면 좌표에 임시로 올라온 텍스트 입력기를 남긴 채 문서를 저장하면
                    // PDF 주석이 편집 중 상태로 직렬화되어 다음 진입 시 문구가 보이지 않을 수 있습니다.
                    // 백그라운드 전환 전에 입력값을 PDF 주석에 먼저 확정합니다.
                    // 텍스트 편집 종료는 주석 타일 재등록과 키보드 해제로 PDFKit 레이아웃을
                    // 변경할 수 있으므로, 사용자가 실제 보고 있는 확대·페이지 좌표를 먼저 저장합니다.
                    self?.persistViewportImmediately()
                    self?.didPersistViewportForBackgroundTransition = true
                    self?.finishTextEditing()
                    self?.persistPageEditDocument()
                    // 복귀 시 동일 문서라는 이유로 복원을 건너뛰지 않도록 복원 캐시를 비웁니다.
                    self?.restoredViewportDocumentID = nil
                    self?.restoredViewportIdentifier = nil
                }
            }
            if memoryWarningObserver == nil {
                memoryWarningObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didReceiveMemoryWarningNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.trimHistoryForMemoryPressure()
                    self?.schedulePDFRenderingCacheRecycle(force: true)
                }
            }
        }

        @objc private func handleViewportGestureEnded(_ recognizer: UIGestureRecognizer) {
            let didFinishGesture = recognizer.state == .ended
                || recognizer.state == .cancelled
                || recognizer.state == .failed
            if recognizer.state == .began {
                // 이전 고배율 제스처가 예약한 문서 재연결이 새 핀치·이동 중
                // 실행되면 PDFKit ScrollView가 해제되며 충돌할 수 있으므로 즉시 취소합니다.
                renderCacheTrimWorkItem?.cancel()
                renderCacheTrimWorkItem = nil
            }
            if let pdfView {
                updateTextActionMenuPosition(in: pdfView)
                updateImageActionMenuPosition(in: pdfView)
                if recognizer === viewportPinchGesture, didFinishGesture {
                    reportZoomPercentage(in: pdfView)
                }
            }
            if recognizer === viewportPinchGesture || recognizer === viewportPanGesture {
                updateActiveTextEditorForViewportGesture(recognizer)
            }
            if recognizer === viewportPinchGesture {
                if didFinishGesture {
                    // FileManager처럼 핀치 중에는 선택 UI도 기존 레이어 트리와 함께 변환하고,
                    // 손을 뗀 뒤 화면상 고정 크기와 고해상도 캐시를 한 번만 갱신합니다.
                    refreshSelectedImageEditingScaleIfNeeded()
                    refreshSelectedTextEditingScaleIfNeeded()
                    refreshSelectedShapeEditingScaleIfNeeded()
                    refreshLassoEditingScaleIfNeeded()
                    // 확대 프레임에서는 레이어 계층만 변환하고, FileManager처럼 손을 뗀 뒤에만
                    // 완료 획의 비트맵 캐시 해상도를 현재 배율에 맞춥니다.
                    pageOverlayViews.values
                        .compactMap { $0 as? PortalPDFInkOverlayView }
                        .forEach { $0.refreshCompletedStrokeRasterizationScale() }
                }
            }
            guard !isRestoringViewport,
                  recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed else {
                return
            }
            viewportSaveWorkItem?.cancel()
            if recognizer === viewportPanGesture {
                // 손을 뗀 뒤 ScrollView 감속 위치까지 반영하되 확대·이동 프레임에는 아무 작업도 하지 않습니다.
                let workItem = DispatchWorkItem { [weak self] in
                    self?.persistViewportImmediately()
                }
                viewportSaveWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
            } else {
                persistViewportImmediately()
            }
            schedulePDFRenderingCacheRecycle(force: false)
        }

        /// 확대·이동 중에도 편집을 종료하지 않고 PDF 페이지 좌표에 맞춰 입력기 위치를 갱신합니다.
        func updateActiveTextEditorForViewportGesture(_ recognizer: UIGestureRecognizer) {
            guard let pdfView,
                  let editor = activeTextEditor,
                  let annotation = selectedTextAnnotation,
                  let page = annotation.page,
                  let editorContainer = editor.superview else { return }
            switch recognizer.state {
            case .began, .changed, .ended, .cancelled:
                pdfView.layoutIfNeeded()
                let frameInPDFView = pdfView.convert(annotation.editingBounds, from: page).standardized
                editor.frame = editorContainer.convert(frameInPDFView, from: pdfView).standardized
                rescaleActiveTextEditor(to: currentPDFScaleFactor)
                if recognizer.state == .ended || recognizer.state == .cancelled {
                    DispatchQueue.main.async { [weak pdfView, weak editor, weak editorContainer] in
                        guard let pdfView, let editor, let editorContainer else { return }
                        pdfView.layoutIfNeeded()
                        let settledFrame = pdfView.convert(annotation.editingBounds, from: page).standardized
                        editor.frame = editorContainer.convert(settledFrame, from: pdfView).standardized
                        self.rescaleActiveTextEditor(to: self.currentPDFScaleFactor)
                    }
                }
            default:
                break
            }
        }

        /// 확대 중 변경된 점선·삭제·변형 핸들의 화면 위치만 즉시 다시 그려 터치 좌표와 일치시킵니다.
        func refreshSelectedImageEditingScaleIfNeeded() {
            guard let pdfView,
                  let annotation = selectedImageAnnotation,
                  annotation.isPortalSelected,
                  let page = annotation.page else { return }
            let previousBounds = annotation.bounds
            guard annotation.updateEditingDisplayScaleFactor(currentPDFScaleFactor) else { return }
            let dirtyPageBounds = previousBounds.union(annotation.bounds).insetBy(dx: -2, dy: -2)
            let dirtyViewBounds = pdfView.convert(dirtyPageBounds, from: page)
            refreshPersistentAnnotationOverlay(on: page)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfView.setNeedsDisplay(dirtyViewBounds)
            if let documentView = pdfView.documentView {
                documentView.setNeedsDisplay(documentView.convert(dirtyViewBounds, from: pdfView))
            }
            CATransaction.commit()
        }

        /// 확대 중 변경된 텍스트 점선·삭제 버튼의 화면 위치와 터치 영역을 즉시 갱신합니다.
        func refreshSelectedTextEditingScaleIfNeeded() {
            guard let pdfView,
                  let annotation = selectedTextAnnotation,
                  annotation.isPortalTextSelected,
                  let page = annotation.page else { return }
            let previousBounds = annotation.bounds
            guard annotation.updateEditingDisplayScaleFactor(currentPDFScaleFactor) else { return }
            let dirtyPageBounds = previousBounds.union(annotation.bounds).insetBy(dx: -2, dy: -2)
            let dirtyViewBounds = pdfView.convert(dirtyPageBounds, from: page)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfView.setNeedsDisplay(dirtyViewBounds)
            if let documentView = pdfView.documentView {
                documentView.setNeedsDisplay(documentView.convert(dirtyViewBounds, from: pdfView))
            }
            CATransaction.commit()
        }

        /// 확대 중 박스 외곽선과 8개 크기 조절점의 화면 크기 및 터치 위치를 갱신합니다.
        func refreshSelectedShapeEditingScaleIfNeeded() {
            guard let pdfView,
                  let annotation = selectedShapeAnnotation,
                  annotation.isPortalSelected,
                  let page = annotation.page else { return }
            let previousBounds = annotation.bounds
            guard annotation.updateEditingDisplayScaleFactor(currentPDFScaleFactor) else { return }
            let dirtyPageBounds = previousBounds.union(annotation.bounds).insetBy(dx: -2, dy: -2)
            let dirtyViewBounds = pdfView.convert(dirtyPageBounds, from: page)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfView.setNeedsDisplay(dirtyViewBounds)
            if let documentView = pdfView.documentView {
                documentView.setNeedsDisplay(documentView.convert(dirtyViewBounds, from: pdfView))
            }
            CATransaction.commit()
        }

        /// PDF 확대·축소 중 확정된 올가미 외곽선과 조작점을 현재 화면 좌표로 갱신합니다.
        func refreshLassoEditingScaleIfNeeded() {
            guard selectedTool == .lasso,
                  let pdfView,
                  activeLassoPage != nil,
                  !selectedLassoAnnotations.isEmpty else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateLassoSelectionOverlay(in: pdfView)
            CATransaction.commit()
        }

        func persistViewportImmediately() {
            viewportSaveWorkItem?.cancel()
            guard !isRestoringViewport,
                  let identifier = viewportPersistenceIdentifier,
                  let pdfView,
                  let scrollView = viewportScrollView(in: pdfView) else { return }
            let viewCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            let anchorPage = pdfView.page(for: viewCenter, nearest: true)
            let pageIndex = anchorPage.flatMap { pdfView.document?.index(for: $0) }
            let pagePoint = anchorPage.map { pdfView.convert(viewCenter, to: $0) }
            PortalPDFViewportStore.save(
                .init(
                    scaleFactor: Double(pdfView.scaleFactor),
                    contentOffsetX: Double(scrollView.contentOffset.x),
                    contentOffsetY: Double(scrollView.contentOffset.y),
                    pageIndex: pageIndex,
                    pagePointX: pagePoint.map { Double($0.x) },
                    pagePointY: pagePoint.map { Double($0.y) }
                ),
                for: identifier
            )
        }

        /// PDFView 해제 시 위치를 한 번만 저장하고 텍스트 편집을 확정합니다.
        /// 백그라운드 전환에서 이미 저장했다면 편집 종료 후 달라진 위치는 다시 저장하지 않습니다.
        func prepareForDismantle() {
            stopActivePenOverlayRefresh()
            renderCacheTrimWorkItem?.cancel()
            zoomPercentageReportWorkItem?.cancel()
            zoomPercentageReportWorkItem = nil
            pendingZoomPercentage = nil
            if !didPersistViewportForBackgroundTransition {
                persistViewportImmediately()
            }
            logViewportAtExit()
            dismissTextActionMenu()
            dismissImageActionMenu()
            finishTextEditing()
            clearTransientNeonStrokes()
            if let pencilInteraction, let pdfView {
                pdfView.removeInteraction(pencilInteraction)
            }
            pencilInteraction = nil
            if let pageChangedObserver {
                NotificationCenter.default.removeObserver(pageChangedObserver)
            }
            pageChangedObserver = nil
            if let scaleChangedObserver {
                NotificationCenter.default.removeObserver(scaleChangedObserver)
            }
            scaleChangedObserver = nil
        }

        /// PDF 화면 종료 직전 사용자가 실제로 보고 있던 위치를 Xcode 콘솔에 기록합니다.
        func logViewportAtExit() {
            guard let pdfView,
                  let scrollView = viewportScrollView(in: pdfView) else {
                print("[NF][PDFViewport][Exit] PDFView 또는 ScrollView를 찾을 수 없습니다.")
                return
            }

            let viewCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            let anchorPage = pdfView.page(for: viewCenter, nearest: true)
            let pageIndex = anchorPage.flatMap { pdfView.document?.index(for: $0) }
            let pagePoint = anchorPage.map { pdfView.convert(viewCenter, to: $0) }
            let identifier = viewportPersistenceIdentifier ?? "nil"
            let pageText = pageIndex.map(String.init) ?? "nil"
            let pageX = pagePoint.map { String(format: "%.3f", $0.x) } ?? "nil"
            let pageY = pagePoint.map { String(format: "%.3f", $0.y) } ?? "nil"
            let scaleText = String(format: "%.4f", pdfView.scaleFactor)
            let offsetX = String(format: "%.3f", scrollView.contentOffset.x)
            let offsetY = String(format: "%.3f", scrollView.contentOffset.y)

            print(
                "[NF][PDFViewport][Exit] id=\(identifier) "
                + "page=\(pageText) scale=\(scaleText) "
                + "offsetX=\(offsetX) offsetY=\(offsetY) "
                + "pageX=\(pageX) pageY=\(pageY)"
            )
        }

        func viewportScrollView(in pdfView: PDFView) -> UIScrollView? {
            // 한 장씩 보기(usePageViewController)에서는 페이지 전환용 ScrollView와
            // 실제 PDF 확대·이동용 ScrollView가 함께 존재합니다. 첫 번째 ScrollView를
            // 사용하면 페이지 전환용 고정 오프셋만 저장되어 실제 화면 위치를 복원할 수 없습니다.
            if let documentView = pdfView.documentView {
                var ancestor: UIView? = documentView
                while let current = ancestor, current !== pdfView {
                    if let scrollView = current as? UIScrollView {
                        return scrollView
                    }
                    ancestor = current.superview
                }
            }

            // documentView 계층이 아직 연결되지 않은 경우 확대 제스처와 실제 이동 범위가
            // 가장 큰 ScrollView를 문서 뷰포트로 선택합니다.
            let candidates = pdfView.recursiveSubviewsIncludingSelf.compactMap { $0 as? UIScrollView }
            return candidates.max { lhs, rhs in
                viewportScrollViewScore(lhs) < viewportScrollViewScore(rhs)
            }
        }

        func viewportScrollViewScore(_ scrollView: UIScrollView) -> CGFloat {
            let scrollableWidth = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            let scrollableHeight = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let zoomScore: CGFloat = scrollView.pinchGestureRecognizer == nil ? 0 : 1_000_000
            return zoomScore + scrollableWidth + scrollableHeight
        }

        func clampedContentOffset(_ proposedOffset: CGPoint, in scrollView: UIScrollView) -> CGPoint {
            let inset = scrollView.adjustedContentInset
            let minimumX = -inset.left
            let minimumY = -inset.top
            let maximumX = max(minimumX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
            let maximumY = max(minimumY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            return CGPoint(
                x: min(max(proposedOffset.x, minimumX), maximumX),
                y: min(max(proposedOffset.y, minimumY), maximumY)
            )
        }

        /// SwiftUI 입력값이 실제로 변경되었을 때만 PDFView 갱신을 허용합니다.
        func shouldApplyRenderState(
            document: PDFDocument,
            selectedTool: PortalPDFMarkupTool,
            penColor: UIColor,
            penLineWidth: CGFloat,
            penType: PortalPDFPenType,
            penPressureStrength: CGFloat,
            penStrokeSmoothingStrength: CGFloat,
            highlighterCap: PortalPDFHighlighterCap,
            shapeType: PortalPDFShapeType,
            shapeLineColor: UIColor,
            shapeFillColor: UIColor,
            textBorderColor: UIColor,
            textFillColor: UIColor,
            textColor: UIColor,
            pendingImage: PortalPDFPendingImage?,
            pendingImageEditCommand: PortalPDFImageEditCommand?,
            pendingShape: PortalPDFPendingShape?,
            pendingText: PortalPDFPendingText?
        ) -> Bool {
            let renderState = RenderState(
                documentID: ObjectIdentifier(document),
                selectedTool: selectedTool,
                penColorComponents: penColor.cgColor.components ?? [],
                penLineWidth: penLineWidth,
                penType: penType,
                penPressureStrength: penPressureStrength,
                penStrokeSmoothingStrength: penStrokeSmoothingStrength,
                highlighterCap: highlighterCap,
                shapeType: shapeType,
                shapeLineColorComponents: shapeLineColor.cgColor.components ?? [],
                shapeFillColorComponents: shapeFillColor.cgColor.components ?? [],
                textBorderColorComponents: textBorderColor.cgColor.components ?? [],
                textFillColorComponents: textFillColor.cgColor.components ?? [],
                textColorComponents: textColor.cgColor.components ?? [],
                pendingImageID: pendingImage?.id,
                pendingImageEditCommandID: pendingImageEditCommand?.id,
                pendingShapeID: pendingShape?.id,
                pendingTextID: pendingText?.id
            )
            guard renderState != lastRenderState else { return false }
            lastRenderState = renderState
            return true
        }

        /**
         PDFView에 편집 제스처를 연결합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - pdfView: 제스처를 연결할 PDFView 입니다.
         */
        func attach(to pdfView: PDFView) {
            self.pdfView = pdfView
            observeViewportChanges(in: pdfView)
            pageChangedObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView] _ in
                guard let self, let pdfView else { return }
                self.reportCurrentPageIndex(in: pdfView)
            }
            scaleChangedObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView] _ in
                guard let self, let pdfView else { return }
                self.reportZoomPercentage(in: pdfView)
            }

            let pencilInteraction = UIPencilInteraction(delegate: self)
            pencilInteraction.isEnabled = UIDevice.current.userInterfaceIdiom == .pad
            pdfView.addInteraction(pencilInteraction)
            self.pencilInteraction = pencilInteraction

            let presentationSwipeUp = UISwipeGestureRecognizer(
                target: self,
                action: #selector(handlePresentationControlSwipe(_:))
            )
            presentationSwipeUp.direction = .up
            presentationSwipeUp.numberOfTouchesRequired = 3
            presentationSwipeUp.cancelsTouchesInView = false
            presentationSwipeUp.delegate = self
            pdfView.addGestureRecognizer(presentationSwipeUp)
            presentationSwipeUpGesture = presentationSwipeUp

            let presentationSwipeDown = UISwipeGestureRecognizer(
                target: self,
                action: #selector(handlePresentationControlSwipe(_:))
            )
            presentationSwipeDown.direction = .down
            presentationSwipeDown.numberOfTouchesRequired = 3
            presentationSwipeDown.cancelsTouchesInView = false
            presentationSwipeDown.delegate = self
            pdfView.addGestureRecognizer(presentationSwipeDown)
            presentationSwipeDownGesture = presentationSwipeDown

            let penDrawing = PortalPDFPenGestureRecognizer(target: self, action: #selector(handlePenDrawing(_:)))
            penDrawing.delegate = self
            // 필기 터치가 PDFKit 본문까지 전달되면 문구 선택·드래그가 동시에 시작될 수 있습니다.
            // 인식된 한 손가락/Apple Pencil 터치만 취소하고 별도 두 손가락 이동·확대는 유지합니다.
            penDrawing.cancelsTouchesInView = true
            penDrawing.delaysTouchesBegan = false
            penDrawing.delaysTouchesEnded = false
            penDrawing.isEnabled = false
            pdfView.addGestureRecognizer(penDrawing)
            penDrawingGesture = penDrawing

            let drawingPan = UIPanGestureRecognizer(target: self, action: #selector(handleDrawingPan(_:)))
            drawingPan.maximumNumberOfTouches = 1
            drawingPan.delegate = self
            drawingPan.cancelsTouchesInView = true
            drawingPan.delaysTouchesBegan = false
            drawingPan.delaysTouchesEnded = false
            pdfView.addGestureRecognizer(drawingPan)
            drawingPanGesture = drawingPan

            let lassoTap = UITapGestureRecognizer(target: self, action: #selector(handleLassoTap(_:)))
            lassoTap.delegate = self
            lassoTap.cancelsTouchesInView = true
            lassoTap.isEnabled = false
            pdfView.addGestureRecognizer(lassoTap)
            lassoTap.require(toFail: drawingPan)
            lassoTapGesture = lassoTap

            let eraserDrawing = PortalPDFEraserGestureRecognizer(
                target: self,
                action: #selector(handleEraserDrawing(_:))
            )
            eraserDrawing.delegate = self
            // 두 번째 손가락이 들어오면 PDFView Pinch/두 손가락 Pan이 이어받을 수 있어야 합니다.
            eraserDrawing.cancelsTouchesInView = false
            eraserDrawing.requiresExclusiveTouchType = false
            eraserDrawing.delaysTouchesBegan = false
            eraserDrawing.delaysTouchesEnded = false
            eraserDrawing.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.pencil.rawValue)
            ]
            eraserDrawing.isEnabled = false
            pdfView.addGestureRecognizer(eraserDrawing)
            eraserDrawingGesture = eraserDrawing

            let imageLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleImageLongPress(_:)))
            imageLongPress.minimumPressDuration = 0.35
            imageLongPress.delegate = self
            imageLongPress.cancelsTouchesInView = true
            pdfView.addGestureRecognizer(imageLongPress)
            imageLongPressGesture = imageLongPress

            // 삭제 버튼은 이미지 본문 밖에 그려져 PDFView 기본 제스처와 쉽게 충돌합니다.
            // 전용 탭 Gesture로 먼저 판정해 길게 누름·스크롤이 삭제 동작을 가로채지 못하게 합니다.
            let imageDeleteTap = UITapGestureRecognizer(target: self, action: #selector(handleSelectedImageDeleteTap(_:)))
            imageDeleteTap.delegate = self
            imageDeleteTap.cancelsTouchesInView = true
            pdfView.addGestureRecognizer(imageDeleteTap)
            imageDeleteTapGesture = imageDeleteTap

            let imageTap = UITapGestureRecognizer(target: self, action: #selector(handleImageTap(_:)))
            imageTap.delegate = self
            imageTap.cancelsTouchesInView = true
            // 이미지 선택은 도구를 다시 전환한 직후에도 지연 없이 반영합니다.
            // 길게 누르기 제스처는 이동이 시작되면 탭을 자동으로 실패시켜 이동 편집을 유지합니다.
            pdfView.addGestureRecognizer(imageTap)
            imageTapGesture = imageTap
            imageTap.require(toFail: imageLongPress)
            imageTap.require(toFail: imageDeleteTap)

            let shapeTap = UITapGestureRecognizer(target: self, action: #selector(handleShapeTap(_:)))
            shapeTap.delegate = self
            shapeTap.cancelsTouchesInView = true
            pdfView.addGestureRecognizer(shapeTap)
            shapeTapGesture = shapeTap
            shapeTap.require(toFail: imageLongPress)

            let textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextTap(_:)))
            textTap.delegate = self
            textTap.cancelsTouchesInView = true
            textTap.isEnabled = false
            pdfView.addGestureRecognizer(textTap)
            textTapGesture = textTap

            let textTouchDown = PortalPDFTextTouchDownGestureRecognizer()
            textTouchDown.cancelsTouchesInView = false
            textTouchDown.delaysTouchesBegan = false
            textTouchDown.delaysTouchesEnded = false
            textTouchDown.isEnabled = false
            textTouchDown.onTouchDown = { [weak self, weak pdfView] point in
                guard let self, let pdfView else { return }
                self.handleTextTouchDown(at: point, in: pdfView)
            }
            pdfView.addGestureRecognizer(textTouchDown)
            textTouchDownGesture = textTouchDown

            let textDeleteTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleSelectedTextDeleteTap(_:))
            )
            textDeleteTap.delegate = self
            textDeleteTap.cancelsTouchesInView = true
            textDeleteTap.isEnabled = false
            pdfView.addGestureRecognizer(textDeleteTap)
            textDeleteTapGesture = textDeleteTap
            textTap.require(toFail: textDeleteTap)

            let textLongPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleTextLongPress(_:))
            )
            textLongPress.minimumPressDuration = 0.35
            textLongPress.delegate = self
            textLongPress.cancelsTouchesInView = true
            textLongPress.isEnabled = false
            pdfView.addGestureRecognizer(textLongPress)
            textLongPressGesture = textLongPress
            textTap.require(toFail: textLongPress)

            let imageRotation = UIRotationGestureRecognizer(target: self, action: #selector(handleImageRotation(_:)))
            imageRotation.delegate = self
            imageRotation.cancelsTouchesInView = true
            pdfView.addGestureRecognizer(imageRotation)
            imageRotationGesture = imageRotation
            prioritizeImageLongPressOverPDFGestures(in: pdfView)
        }

        /**
         SwiftUI에서 선택한 PDF 편집 도구를 PDFView 제스처 환경에 반영합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - tool: 사용자가 선택한 PDF 편집 도구입니다.
            - pdfView: 도구 상태를 반영할 PDFView 입니다.
         */
        func updateSelectedTool(_ tool: PortalPDFMarkupTool, in pdfView: PDFView) {
            /// 편집 도구의 한 손가락 동작과 PDF 이동을 분리하기 위해 편집 중에는 ScrollView Pan을 두 손가락부터 시작합니다.
            if selectedTool != tool {
                dismissTextActionMenu()
                dismissImageActionMenu()
                if selectedTool == .text {
                    finishTextEditing()
                    clearSelectedTextAnnotation(in: pdfView)
                }
                resetActiveDrawing()
                clearLassoSelection()
            }
            selectedTool = tool
            textLongPressGesture?.isEnabled = tool == .text && activeTextEditor == nil
            if let activeTextEditor {
                restoreNativeTextEditorGestures(activeTextEditor)
            }
            penDrawingGesture?.isEnabled = tool.isInkTool
            if tool == .handwriting {
                // iPad 손글씨는 기존 손가락 필기 동작을 그대로 사용합니다.
                penDrawingGesture?.requiredTouchType = .direct
            } else if (tool == .pen || tool == .highlighter || tool == .neon), UIDevice.current.userInterfaceIdiom == .pad {
                // iPad 팬슬 모드는 Apple Pencil 입력만 경로로 받습니다.
                penDrawingGesture?.requiredTouchType = .pencil
            } else {
                // iPhone 펜 모드는 기존과 동일하게 손가락 입력을 사용합니다.
                penDrawingGesture?.requiredTouchType = .direct
            }
            if let requiredTouchType = penDrawingGesture?.requiredTouchType {
                penDrawingGesture?.allowedTouchTypes = [NSNumber(value: requiredTouchType.rawValue)]
            } else {
                penDrawingGesture?.allowedTouchTypes = []
            }
            let isTransformEditing = tool == .image || tool == .box
            drawingPanGesture?.isEnabled = isTransformEditing || tool == .lasso || tool == .text
            lassoTapGesture?.isEnabled = tool == .lasso
            eraserDrawingGesture?.isEnabled = tool == .eraser
            // 보기 도구에서는 PDF 화면 이동만 허용하고, 이미지·박스 편집용 롱프레스가
            // 한 손가락 이동을 가로채지 않도록 편집 모드에서만 활성화합니다.
            imageLongPressGesture?.isEnabled = isTransformEditing
            imageTapGesture?.isEnabled = tool == .image
            imageDeleteTapGesture?.isEnabled = tool == .image
            shapeTapGesture?.isEnabled = tool == .box
            // 활성 UITextView가 있는 동안 PDF용 텍스트 선택 탭을 다시 켜면
            // cancelsTouchesInView가 커서 이동·문구 선택·드래그를 취소합니다.
            textTapGesture?.isEnabled = tool == .text
            textTouchDownGesture?.isEnabled = tool.supportsDirectObjectSelection
            textDeleteTapGesture?.isEnabled = tool == .text
            imageRotationGesture?.isEnabled = isTransformEditing
            if tool == .image {
                // 이미지 편집 모드에서는 현재 선택 이미지 하나만 편집 컨트롤을 유지합니다.
                // 이전 렌더링 상태가 남아 있어도 다른 이미지의 점선·삭제·변형 핸들은 즉시 숨깁니다.
                retainOnlySelectedImageAnnotation(in: pdfView)
            } else {
                // 도구가 무엇이었는지와 관계없이 이미지 편집 모드가 아닌 순간에는
                // 문서 전체의 이미지 선택선을 해제합니다. PDFKit 타일 캐시가 이전
                // 점선·핸들을 남기는 경우가 있어 Portal 주석을 다시 등록해 즉시 갱신합니다.
                deactivateAllImageEditing(in: pdfView, forceRedraw: true)
            }
            if tool != .box {
                clearSelectedShapeAnnotation()
            }
            let isViewing = tool == .view
            let isEditing = !isViewing
            (pdfView as? PortalPDFView)?.suppressesDocumentActions = isEditing
            if isEditing {
                // 모든 편집 모드에서 기존 텍스트 선택과 편집 메뉴를 즉시 제거합니다.
                pdfView.clearSelection()
            }
            configureDocumentScrollGestures(in: pdfView)
            updatePDFViewTransformGestures(
                isViewing: isViewing,
                isEditing: isEditing,
                in: pdfView
            )
            if isEditing {
                // PDFKit이 문서 연결 직후 내부 선택 제스처를 늦게 추가하는 경우까지 차단합니다.
                DispatchQueue.main.async { [weak self, weak pdfView] in
                    guard let self, let pdfView, self.selectedTool != .view else { return }
                    self.updatePDFViewTransformGestures(
                        isViewing: false,
                        isEditing: true,
                        in: pdfView
                    )
                }
            }
        }

        /// 현재 편집 도구에 맞춰 PDF 문서 ScrollView의 이동 터치 수를 적용합니다.
        /// PDFKit이 재진입 위치 복원 중 내부 ScrollView를 교체해도 이 메서드를 다시 호출할 수 있습니다.
        func configureDocumentScrollGestures(in pdfView: PDFView) {
            let isViewing = selectedTool == .view
            let isInkEditing = selectedTool.isInkTool
            pdfView.recursiveScrollViews.forEach { scrollView in
                if let activeTextEditor,
                   scrollView === activeTextEditor || scrollView.isDescendant(of: activeTextEditor) {
                    return
                }
                scrollView.isScrollEnabled = true
                scrollView.panGestureRecognizer.isEnabled = true
                // 펜슬 모드에서는 한 손가락을 Apple Pencil 입력과 분리하고,
                // 두 손가락만 PDF 화면 이동으로 사용합니다.
                scrollView.panGestureRecognizer.minimumNumberOfTouches = isViewing ? 1 : 2
                scrollView.panGestureRecognizer.maximumNumberOfTouches = isInkEditing ? 2 : Int.max
                // Apple Pencil은 문서 스크롤이 가로채지 않고, 손가락만 이동 제스처로 사용합니다.
                scrollView.panGestureRecognizer.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue),
                    NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
                ]
                if isViewing {
                    // 편집 모드에서 남은 PDFKit 팬 제스처 상태를 초기화해
                    // 보기 도구 전환 직후에도 한 손가락 이동을 즉시 허용합니다.
                    scrollView.panGestureRecognizer.isEnabled = false
                    scrollView.panGestureRecognizer.isEnabled = true
                }
            }
        }

        /**
         이미지 편집 모드 진입 이벤트를 최신 SwiftUI Closure로 갱신합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - handler: 이미지 편집 모드 진입 시 실행할 SwiftUI 상태 갱신 이벤트입니다.
         */
        func updateActivationHandler(_ handler: @escaping () -> Void) {
            onActivateImageTool = handler
        }

        /// 도형 편집 모드 진입 이벤트를 최신 SwiftUI Closure로 갱신합니다.
        func updateShapeActivationHandler(_ handler: @escaping () -> Void) {
            onActivateShapeTool = handler
        }

        /// 텍스트 박스 선택으로 편집 모드가 바뀔 때 사용할 최신 SwiftUI Closure를 연결합니다.
        func updateTextActivationHandler(_ handler: @escaping () -> Void) {
            onActivateTextTool = handler
        }

        /// 이미지 말풍선 메뉴 명령을 받을 최신 SwiftUI Closure를 연결합니다.
        func updateImageActionHandler(_ handler: @escaping (PortalPDFImageAction) -> Void) {
            onImageActionRequested = handler
        }

        /// 펜 드로잉 시작 이벤트를 최신 SwiftUI Closure와 연결합니다.
        func updatePenDrawingHandler(_ handler: @escaping () -> Void) {
            onBeginPenDrawing = handler
        }

        /// Apple Pencil 이중 탭 이벤트를 최신 SwiftUI Closure와 연결합니다.
        func updatePencilDoubleTapHandler(_ handler: @escaping () -> Void) {
            onPencilDoubleTap = handler
        }

        /// 프레젠테이션 제어 UI 표시 이벤트를 최신 SwiftUI Closure와 연결합니다.
        func updatePresentationControlsRevealHandler(_ handler: @escaping () -> Void) {
            onPresentationControlsReveal = handler
        }

        /// PDFView 페이지 변경을 받을 최신 SwiftUI 콜백을 저장합니다.
        func updateCurrentPageChangedHandler(_ handler: @escaping (Int) -> Void) {
            onCurrentPageChanged = handler
        }

        /// PDFView 확대 배율 변경을 받을 최신 SwiftUI 콜백을 저장합니다.
        func updateZoomPercentageChangedHandler(_ handler: @escaping (Int) -> Void) {
            onZoomPercentageChanged = handler
        }

        /// 현재 페이지 번호가 달라진 경우에만 다음 RunLoop에서 SwiftUI 상태를 갱신합니다.
        func reportCurrentPageIndex(in pdfView: PDFView) {
            guard let document = pdfView.document,
                  let currentPage = pdfView.currentPage else { return }
            let pageIndex = document.index(for: currentPage)
            guard pageIndex != NSNotFound,
                  lastReportedCurrentPageIndex != pageIndex else { return }
            lastReportedCurrentPageIndex = pageIndex
            let handler = onCurrentPageChanged
            DispatchQueue.main.async {
                handler(pageIndex)
            }
        }

        /// 현재 배율을 퍼센트로 변환해 핀치 중 변경될 때만 SwiftUI 표시를 갱신합니다.
        func reportZoomPercentage(in pdfView: PDFView) {
            let percentage = max(1, Int((pdfView.scaleFactor * 100).rounded()))
            if zoomPercentageReportWorkItem != nil {
                pendingZoomPercentage = percentage
                return
            }
            guard lastReportedZoomPercentage != percentage else { return }
            pendingZoomPercentage = percentage

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.zoomPercentageReportWorkItem = nil
                guard let latestPercentage = self.pendingZoomPercentage else { return }
                self.pendingZoomPercentage = nil
                guard self.lastReportedZoomPercentage != latestPercentage else { return }
                self.lastReportedZoomPercentage = latestPercentage
                self.onZoomPercentageChanged(latestPercentage)
            }
            zoomPercentageReportWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 30.0), execute: workItem)
        }

        /// Apple Pencil 측면 이중 탭을 받습니다. 진행 중인 획이 있으면 획 저장 후 전환합니다.
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            guard UIDevice.current.userInterfaceIdiom == .pad else { return }
            if activePenPage != nil {
                hasPendingPencilDoubleTap = true
            } else {
                onPencilDoubleTap()
            }
        }

        func performPendingPencilDoubleTapIfNeeded() {
            guard hasPendingPencilDoubleTap else { return }
            hasPendingPencilDoubleTap = false
            DispatchQueue.main.async { [weak self] in
                self?.onPencilDoubleTap()
            }
        }

        /// 이미지 Annotation 선택 여부 전달 Closure를 최신 SwiftUI 상태와 연결합니다.
        func updateImageSelectionHandler(_ handler: @escaping (Bool) -> Void) {
            onImageSelectionChanged = handler
        }

        /// 시스템 이미지 편집 요청 Closure를 최신 SwiftUI 상태와 연결합니다.
        func updateSystemImageEditHandler(_ handler: @escaping (UIImage) -> Void) {
            onSystemImageEditRequested = handler
        }

        /// 전용 이미지 자르기 화면 요청 Closure를 최신 SwiftUI 상태와 연결합니다.
        func updateImageCropHandler(_ handler: @escaping (UIImage) -> Void) {
            onImageCropRequested = handler
        }

        /// 도형 Annotation 선택 여부 전달 Closure를 최신 SwiftUI 상태와 연결합니다.
        func updateShapeSelectionHandler(_ handler: @escaping (Bool) -> Void) {
            onShapeSelectionChanged = handler
        }

        /// PDF 변경 이벤트를 최신 SwiftUI 자동 저장 Closure와 연결합니다.
        func updateDocumentChangedHandler(_ handler: @escaping () -> Void) {
            documentChangedHandler = handler
        }

        func updateHistoryAvailabilityHandler(_ handler: @escaping (Bool, Bool) -> Void) {
            onHistoryAvailabilityChanged = handler
            reportHistoryAvailability()
        }

        /// 현재 문서의 최초 Annotation 상태를 실행 취소 기준점으로 설정합니다.
        func configureHistoryIfNeeded(for document: PDFDocument) {
            let documentID = ObjectIdentifier(document)
            guard historyDocumentID != documentID else { return }
            historyDocumentID = documentID
            undoHistorySnapshots.removeAll(keepingCapacity: true)
            redoHistorySnapshots.removeAll(keepingCapacity: true)
            currentHistorySnapshot = makeHistorySnapshot(for: document)
            lastAppliedHistoryCommandID = nil
            reportHistoryAvailability()
        }

        /// PDFKit 타일 캐시가 커지는 순간 가용 메모리를 확보하도록 오래된 편집 기록을 정리합니다.
        func trimHistoryForMemoryPressure() {
            let retainedUndoCount = 2
            if undoHistorySnapshots.count > retainedUndoCount {
                undoHistorySnapshots.removeFirst(undoHistorySnapshots.count - retainedUndoCount)
            }
            redoHistorySnapshots.removeAll(keepingCapacity: false)
            reportHistoryAvailability()
        }

        /// 제스처 종료 뒤 고배율 타일 메모리를 확인하고 필요한 경우 한 번만 캐시 교체를 예약합니다.
        func schedulePDFRenderingCacheRecycle(force: Bool, delay: TimeInterval? = nil) {
            renderCacheTrimWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.renderCacheTrimWorkItem = nil
                self.recyclePDFRenderingCacheIfNeeded(force: force)
            }
            renderCacheTrimWorkItem = workItem
            let resolvedDelay = delay ?? (force ? 0 : 0.7)
            DispatchQueue.main.asyncAfter(deadline: .now() + resolvedDelay, execute: workItem)
        }

        /// PDFKit의 내부 ScrollView가 핀치·이동·감속 중인지 확인합니다.
        /// 이 시점에 문서를 분리하면 현재 제스처가 참조하는 View 계층과 충돌합니다.
        func isViewportInteractionActive(in pdfView: PDFView) -> Bool {
            let activeGestureStates: Set<UIGestureRecognizer.State> = [.began, .changed]
            if let pinchGesture = viewportPinchGesture,
               activeGestureStates.contains(pinchGesture.state) {
                return true
            }
            if let panGesture = viewportPanGesture,
               activeGestureStates.contains(panGesture.state) {
                return true
            }
            guard let scrollView = viewportScrollView(in: pdfView) else { return false }
            return scrollView.isZooming || scrollView.isDragging || scrollView.isDecelerating
        }

        /// PDFDocument와 현재 페이지 좌표·배율은 유지하고 PDFKit 내부 렌더 뷰만 재생성합니다.
        /// 고배율로 여러 영역을 본 뒤 누적된 CATiledLayer 캐시를 실제 메모리에서 해제합니다.
        func recyclePDFRenderingCacheIfNeeded(force: Bool) {
            guard !isRecyclingPDFRenderingCache,
                  !isRestoringViewport,
                  let pdfView,
                  let document = pdfView.document,
                  force || pdfView.scaleFactor >= 4 else { return }

            if isViewportInteractionActive(in: pdfView) {
                // 메모리 경고도 현재 핀치 한 프레임을 안전하게 마친 뒤 처리합니다.
                schedulePDFRenderingCacheRecycle(force: force, delay: 0.25)
                return
            }

            let currentMemory = PortalPDFProcessMemory.residentBytes()
            if pdfRenderingMemoryBaseline == 0 {
                pdfRenderingMemoryBaseline = currentMemory
            }
            let growth = currentMemory >= pdfRenderingMemoryBaseline
                ? currentMemory - pdfRenderingMemoryBaseline
                : 0
            let shouldRecycle = force
                || growth >= 300 * 1_048_576
                || currentMemory >= 700 * 1_048_576
            guard shouldRecycle else { return }
            let now = CACurrentMediaTime()
            guard force || now - lastRenderCacheRecycleTime >= 3 else { return }

            let viewportCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            guard let page = pdfView.page(for: viewportCenter, nearest: true) ?? pdfView.currentPage else { return }
            let pagePoint = pdfView.convert(viewportCenter, to: page)
            let scaleFactor = pdfView.scaleFactor
            let wasAutoScaling = pdfView.autoScales
            let transitionSnapshot = pdfView.snapshotView(afterScreenUpdates: false)
            transitionSnapshot?.frame = pdfView.bounds
            transitionSnapshot?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            transitionSnapshot?.isUserInteractionEnabled = false
            if let transitionSnapshot {
                pdfView.addSubview(transitionSnapshot)
            }

            isRecyclingPDFRenderingCache = true
            renderCacheRecycleCount += 1
            lastRenderCacheRecycleTime = now
            pdfView.document = nil
            pageOverlayViews.removeAll(keepingCapacity: true)
            pdfView.layoutDocumentView()
            pdfView.layoutIfNeeded()

            // detach·attach를 같은 RunLoop에서 실행하면 기존 고배율 타일과
            // 새 타일이 동시에 존재해 메모리 피크가 커집니다. 다음 RunLoop에 재연결합니다.
            DispatchQueue.main.async { [weak self, weak pdfView, weak transitionSnapshot] in
                guard let self, let pdfView else {
                    transitionSnapshot?.removeFromSuperview()
                    return
                }
                guard self.pdfView === pdfView else {
                    transitionSnapshot?.removeFromSuperview()
                    self.isRecyclingPDFRenderingCache = false
                    return
                }

                pdfView.autoScales = false
                pdfView.document = document
                pdfView.maxScaleFactor = 10
                pdfView.scaleFactor = min(max(scaleFactor, pdfView.minScaleFactor), pdfView.maxScaleFactor)
                pdfView.layoutDocumentView()
                pdfView.layoutIfNeeded()
                _ = self.restorePageAnchor(pagePoint, on: page, in: pdfView)
                pdfView.autoScales = wasAutoScaling
                self.observeViewportChanges(in: pdfView)
                self.configureDocumentScrollGestures(in: pdfView)
                self.refreshPersistentInkOverlays()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak transitionSnapshot] in
                    transitionSnapshot?.removeFromSuperview()
                    guard let self else { return }
                    self.pdfRenderingMemoryBaseline = PortalPDFProcessMemory.residentBytes()
                    self.isRecyclingPDFRenderingCache = false
                }
            }
        }

        /// 변경 페이지가 주어지면 해당 페이지만 캡처·렌더하고 자동 저장과 히스토리를 확정합니다.
        func onDocumentChanged(
            changedPages: [PDFPage] = [],
            appendedAnnotation: PDFAnnotation? = nil,
            appendedStrokeRasterReady: (() -> Void)? = nil
        ) {
            let usedAppendFastPath: Bool
            if let appendedAnnotation,
               changedPages.count == 1,
               let page = changedPages.first {
                usedAppendFastPath = appendPageEditAnnotation(
                    appendedAnnotation,
                    on: page,
                    strokeRasterReady: appendedStrokeRasterReady
                )
            } else {
                usedAppendFastPath = false
            }
            if usedAppendFastPath {
                // 정본과 해당 페이지 Overlay가 이미 증분 갱신됐습니다.
            } else if changedPages.isEmpty {
                refreshPersistentInkOverlays()
            } else {
                var visited: Set<ObjectIdentifier> = []
                changedPages.forEach { page in
                    let identifier = ObjectIdentifier(page)
                    guard visited.insert(identifier).inserted else { return }
                    refreshPersistentAnnotationOverlay(on: page)
                }
            }
            if !usedAppendFastPath, let appendedStrokeRasterReady {
                DispatchQueue.main.async(execute: appendedStrokeRasterReady)
            }
            schedulePageEditPersistence()
            guard !isApplyingHistory else {
                documentChangedHandler()
                return
            }
            if let document = pdfView?.document,
               let previousSnapshot = currentHistorySnapshot {
                undoHistorySnapshots.append(previousSnapshot)
                let historyLimit = PortalPDFHistoryPolicy.maximumUndoCount(for: document)
                if undoHistorySnapshots.count > historyLimit {
                    undoHistorySnapshots.removeFirst(undoHistorySnapshots.count - historyLimit)
                }
                currentHistorySnapshot = makeHistorySnapshot(
                    for: document,
                    updating: changedPages,
                    basedOn: previousSnapshot,
                    appendedAnnotation: usedAppendFastPath ? appendedAnnotation : nil
                )
                redoHistorySnapshots.removeAll(keepingCapacity: true)
                reportHistoryAvailability()
            }
            documentChangedHandler()
        }

        func applyHistoryCommandIfNeeded(_ command: PortalPDFHistoryCommand?, in pdfView: PDFView) {
            guard let command, lastAppliedHistoryCommandID != command.id else { return }
            lastAppliedHistoryCommandID = command.id

            // 지우개는 입력 좌표를 30fps 작업으로 묶어 처리하므로 Undo/Redo가 먼저 실행되면
            // 복원 전 PDFPage/Annotation을 예약 작업이 다시 변경할 수 있습니다. 히스토리 배열을
            // 읽기 전에 현재 지우개 세션을 확정하고 Gesture 참조를 초기화합니다.
            finishActiveEraserBeforeHistory(in: pdfView)
            guard let currentSnapshot = currentHistorySnapshot else { return }

            let targetSnapshot: AnnotationHistorySnapshot
            switch command.operation {
            case .undo:
                guard let snapshot = undoHistorySnapshots.popLast() else { return }
                redoHistorySnapshots.append(currentSnapshot)
                targetSnapshot = snapshot
            case .redo:
                guard let snapshot = redoHistorySnapshots.popLast() else { return }
                undoHistorySnapshots.append(currentSnapshot)
                targetSnapshot = snapshot
            }
            applyHistorySnapshot(targetSnapshot, in: pdfView)
            currentHistorySnapshot = targetSnapshot
            reportHistoryAvailability()
            documentChangedHandler()
        }

        /// 현재 표시 중인 페이지 바로 아래에 빈 페이지 또는 복제 페이지를 삽입합니다.
        func applyPageEditCommandIfNeeded(
            _ command: PortalPDFPageEditCommand?,
            in pdfView: PDFView
        ) {
            guard let command, lastAppliedPageEditCommandID != command.id else { return }
            lastAppliedPageEditCommandID = command.id
            guard let document = pdfView.document,
                  let currentPage = pdfView.currentPage else { return }
            let currentIndex = document.index(for: currentPage)
            guard currentIndex != NSNotFound else { return }

            finishActiveEraserBeforeHistory(in: pdfView)
            clearSelectedImageAnnotation()
            clearSelectedShapeAnnotation()
            clearLassoSelection()

            let insertedPage: PDFPage?
            switch command.operation {
            case .addBlankPage:
                insertedPage = makeBlankPage(matching: currentPage)
            case .duplicateCurrentPage:
                insertedPage = duplicatePage(at: currentIndex, from: document)
            }
            guard let insertedPage else { return }

            let insertionIndex = min(currentIndex + 1, document.pageCount)
            document.insert(insertedPage, at: insertionIndex)
            restoreEditableAnnotations(on: insertedPage)
            resetHistoryAfterPageStructureChange(for: document)
            pdfView.layoutDocumentView()
            pdfView.layoutIfNeeded()
            pdfView.go(to: insertedPage)
            lastReportedCurrentPageIndex = nil
            reportCurrentPageIndex(in: pdfView)
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
            documentChangedHandler()
        }

        /// 전체 페이지 썸네일에서 선택한 페이지로 현재 확대 배율을 유지한 채 이동합니다.
        func applyPageNavigationCommandIfNeeded(
            _ command: PortalPDFPageNavigationCommand?,
            in pdfView: PDFView
        ) {
            guard let command,
                  lastAppliedPageNavigationCommandID != command.id else { return }
            lastAppliedPageNavigationCommandID = command.id
            guard let document = pdfView.document,
                  command.pageIndex >= 0,
                  command.pageIndex < document.pageCount,
                  let page = document.page(at: command.pageIndex) else { return }

            finishTextEditing()
            dismissTextActionMenu()
            clearSelectedTextAnnotation(in: pdfView)
            clearSelectedImageAnnotation()
            clearSelectedShapeAnnotation()
            clearLassoSelection()
            pdfView.go(to: page)
            lastReportedCurrentPageIndex = nil
            reportCurrentPageIndex(in: pdfView)
        }

        /// 전체 페이지 편집 결과를 PDFView 레이아웃·히스토리·자동 저장 상태에 반영합니다.
        func applyPageStructureRefreshCommandIfNeeded(
            _ command: PortalPDFPageStructureRefreshCommand?,
            in pdfView: PDFView
        ) {
            guard let command,
                  lastAppliedPageStructureRefreshCommandID != command.id else { return }
            lastAppliedPageStructureRefreshCommandID = command.id
            guard let document = pdfView.document, document.pageCount > 0 else { return }

            finishTextEditing()
            dismissTextActionMenu()
            clearSelectedTextAnnotation(in: pdfView)
            clearSelectedImageAnnotation()
            clearSelectedShapeAnnotation()
            clearLassoSelection()
            resetHistoryAfterPageStructureChange(for: document)
            pdfView.layoutDocumentView()
            pdfView.layoutIfNeeded()

            let targetIndex = min(max(command.selectedPageIndex, 0), document.pageCount - 1)
            if let page = document.page(at: targetIndex) {
                pdfView.go(to: page)
            }
            lastReportedCurrentPageIndex = nil
            reportCurrentPageIndex(in: pdfView)
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
            documentChangedHandler()
        }

        /// 현재 페이지와 같은 크기의 흰색 빈 PDF 페이지를 생성합니다.
        func makeBlankPage(matching sourcePage: PDFPage) -> PDFPage? {
            let sourceBounds = sourcePage.bounds(for: .mediaBox)
            let pageBounds = CGRect(origin: .zero, size: sourceBounds.size)
            let data = NSMutableData()
            UIGraphicsBeginPDFContextToData(data, pageBounds, nil)
            UIGraphicsBeginPDFPageWithInfo(pageBounds, nil)
            UIColor.white.setFill()
            UIRectFill(pageBounds)
            UIGraphicsEndPDFContext()
            return PDFDocument(data: data as Data)?.page(at: 0)
        }

        /// 현재 편집 메타데이터까지 포함한 문서 사본에서 지정 페이지를 분리합니다.
        func duplicatePage(at pageIndex: Int, from document: PDFDocument) -> PDFPage? {
            guard let data = document.portalEditableDataRepresentation(),
                  let copiedDocument = PDFDocument(data: data),
                  let copiedPage = copiedDocument.page(at: pageIndex) else { return nil }
            copiedDocument.removePage(at: pageIndex)
            return copiedPage
        }

        /// 복제 페이지의 저장용 Stamp를 다시 선택·이동 가능한 앱 편집 Annotation으로 변환합니다.
        func restoreEditableAnnotations(on page: PDFPage) {
            let annotations = page.annotations
            let restoredAnnotations = annotations.map { annotation in
                PortalPDFImageAnnotation.restored(from: annotation)
                    ?? PortalPDFShapeAnnotation.restored(from: annotation)
                    ?? PortalPDFTextAnnotation.restored(from: annotation)
                    ?? annotation
            }
            guard zip(annotations, restoredAnnotations).contains(where: { $0 !== $1 }) else { return }
            annotations.forEach { page.removeAnnotation($0) }
            restoredAnnotations.forEach { page.addAnnotation($0) }
        }

        /// 페이지 수가 바뀐 뒤 이전 페이지 배열 기반 Undo 스냅샷을 새 기준점으로 초기화합니다.
        func resetHistoryAfterPageStructureChange(for document: PDFDocument) {
            historyDocumentID = ObjectIdentifier(document)
            undoHistorySnapshots.removeAll(keepingCapacity: true)
            redoHistorySnapshots.removeAll(keepingCapacity: true)
            currentHistorySnapshot = makeHistorySnapshot(for: document)
            lastAppliedHistoryCommandID = nil
            reportHistoryAvailability()
        }

        func reportHistoryAvailability() {
            let availability = (
                canUndo: !undoHistorySnapshots.isEmpty,
                canRedo: !redoHistorySnapshots.isEmpty
            )
            guard lastReportedHistoryAvailability?.canUndo != availability.canUndo
                    || lastReportedHistoryAvailability?.canRedo != availability.canRedo else { return }
            lastReportedHistoryAvailability = availability
            let handler = onHistoryAvailabilityChanged
            DispatchQueue.main.async {
                handler(availability.canUndo, availability.canRedo)
            }
        }

        func makeHistorySnapshot(for document: PDFDocument) -> AnnotationHistorySnapshot {
            let pages = (0..<document.pageCount).map { pageIndex -> [AnnotationHistoryRecord] in
                guard let page = document.page(at: pageIndex) else { return [] }
                return page.annotations.map(historyRecord(for:))
            }
            return AnnotationHistorySnapshot(
                documentID: ObjectIdentifier(document),
                pageAnnotations: pages
            )
        }

        /// 페이지 구조가 그대로인 일반 편집은 변경된 페이지의 히스토리만 교체합니다.
        /// 이미지가 많은 다른 페이지까지 매 획마다 복제하지 않아 펜 종료 지연을 줄입니다.
        func makeHistorySnapshot(
            for document: PDFDocument,
            updating changedPages: [PDFPage],
            basedOn previousSnapshot: AnnotationHistorySnapshot,
            appendedAnnotation: PDFAnnotation? = nil
        ) -> AnnotationHistorySnapshot {
            guard !changedPages.isEmpty,
                  previousSnapshot.documentID == ObjectIdentifier(document),
                  previousSnapshot.pageAnnotations.count == document.pageCount else {
                return makeHistorySnapshot(for: document)
            }
            var pageAnnotations = previousSnapshot.pageAnnotations
            var visited: Set<Int> = []
            for page in changedPages {
                let pageIndex = document.index(for: page)
                guard pageIndex != NSNotFound,
                      pageAnnotations.indices.contains(pageIndex),
                      visited.insert(pageIndex).inserted else { continue }
                if let appendedAnnotation,
                   appendedAnnotation.page === page,
                   page.annotations.last === appendedAnnotation {
                    pageAnnotations[pageIndex].append(historyRecord(for: appendedAnnotation))
                } else {
                    pageAnnotations[pageIndex] = page.annotations.map(historyRecord(for:))
                }
            }
            return AnnotationHistorySnapshot(
                documentID: ObjectIdentifier(document),
                pageAnnotations: pageAnnotations
            )
        }

        /// PDFAnnotation 객체와 PDFKit 렌더 캐시는 보관하지 않고 복원에 필요한 값만 기록합니다.
        func historyRecord(for annotation: PDFAnnotation) -> AnnotationHistoryRecord {
            if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                return .image(imageAnnotation.historyState)
            }
            if annotation is PortalPDFShapeAnnotation,
               let contents = annotation.contents {
                return .shape(bounds: annotation.bounds, contents: contents)
            }
            if annotation is PortalPDFTextAnnotation,
               let contents = annotation.contents {
                return .text(bounds: annotation.bounds, contents: contents)
            }
            if let storedPressure = PortalPDFPressureInkAnnotation.historyStrokes(in: annotation) {
                return .pressure(
                    fragments: storedPressure.fragments,
                    lineWidth: storedPressure.lineWidth,
                    color: PortalPDFPressureInkAnnotation.storedColor(in: annotation)
                )
            }
            if annotation.isPortalInkAnnotation {
                return .ink(
                    bounds: annotation.bounds,
                    paths: annotation.paths?.map(\.cgPath) ?? [],
                    color: annotation.color,
                    lineWidth: annotation.border?.lineWidth ?? 1,
                    contents: annotation.contents,
                    userName: annotation.userName
                )
            }
            return .retained(annotation)
        }

        func annotation(from record: AnnotationHistoryRecord) -> PDFAnnotation {
            switch record {
            case .retained(let annotation):
                return annotation
            case .image(let state):
                return PortalPDFImageAnnotation.annotation(from: state)
            case .shape(let bounds, let contents):
                let proxy = PDFAnnotation(bounds: bounds, forType: .stamp, withProperties: nil)
                proxy.contents = contents
                return PortalPDFShapeAnnotation.restored(from: proxy) ?? proxy
            case .text(let bounds, let contents):
                let proxy = PDFAnnotation(bounds: bounds, forType: .stamp, withProperties: nil)
                proxy.contents = contents
                return PortalPDFTextAnnotation.restored(from: proxy) ?? proxy
            case .pressure(let fragments, let lineWidth, let color):
                return PortalPDFPressureInkAnnotation.groupedAnnotation(
                    fragments: fragments,
                    baseLineWidth: lineWidth,
                    color: color
                ) ?? PDFAnnotation(bounds: .zero, forType: .stamp, withProperties: nil)
            case .ink(let bounds, let paths, let color, let lineWidth, let contents, let userName):
                let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                annotation.color = color
                annotation.contents = contents
                annotation.userName = userName
                let border = PDFBorder()
                border.lineWidth = lineWidth
                annotation.border = border
                paths.forEach { annotation.add(UIBezierPath(cgPath: $0)) }
                return annotation
            }
        }

        /// 히스토리 복원 시 새 객체로 교체해야 하는 앱 편집 Annotation 기록인지 확인합니다.
        func isHistoryEditableRecord(_ record: AnnotationHistoryRecord) -> Bool {
            if case .retained = record { return false }
            return true
        }

        /// PDFDocument와 PDFPage는 유지하고 Annotation 배열만 복원해 화면 재진입식 깜빡임을 피합니다.
        func applyHistorySnapshot(_ snapshot: AnnotationHistorySnapshot, in pdfView: PDFView) {
            guard let document = pdfView.document,
                  snapshot.documentID == ObjectIdentifier(document) else { return }
            isApplyingHistory = true
            defer { isApplyingHistory = false }
            clearSelectedImageAnnotation()
            clearSelectedShapeAnnotation()

            var dirtyViewRects: [CGRect] = []
            for pageIndex in 0..<min(document.pageCount, snapshot.pageAnnotations.count) {
                guard let page = document.page(at: pageIndex) else { continue }
                // PDF 자체 주석은 제거하거나 같은 객체를 재삽입하지 않습니다. 앱에서 만든 편집
                // 주석만 새 객체로 복원해 PDFKit 내부 page 참조가 끊긴 객체를 지우개가 만지는
                // 상황을 방지합니다.
                page.annotations.filter(isHistoryEditableAnnotation).forEach { annotation in
                    annotation.shouldDisplay = false
                    annotation.shouldPrint = false
                    dirtyViewRects.append(pdfView.convert(annotation.bounds, from: page))
                    page.removeAnnotation(annotation)
                }
                snapshot.pageAnnotations[pageIndex]
                    .filter(isHistoryEditableRecord)
                    .forEach { record in
                    let restoredAnnotation = annotation(from: record)
                    restoredAnnotation.shouldDisplay = true
                    restoredAnnotation.shouldPrint = true
                    page.addAnnotation(restoredAnnotation)
                    dirtyViewRects.append(pdfView.convert(restoredAnnotation.bounds, from: page))
                }
            }
            pdfView.layoutDocumentView()
            pdfView.layoutIfNeeded()
            refreshPersistentInkOverlays()
            refreshPDFViewDuringEraser(in: pdfView, dirtyViewRects: dirtyViewRects)
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
            // PDFKit 타일 갱신은 비동기로 예약되므로 다음 RunLoop에서도 이전·복원 영역을
            // 다시 무효화해 Undo 직전 화면이 잔상으로 남는 것을 제거합니다.
            let finalDirtyViewRects = dirtyViewRects
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                self.refreshPDFViewDuringEraser(in: pdfView, dirtyViewRects: finalDirtyViewRects)
                self.refreshPDFViewAfterAnnotationMutation(in: pdfView)
            }
        }

        func isHistoryEditableAnnotation(_ annotation: PDFAnnotation) -> Bool {
            annotation is PortalPDFImageAnnotation
                || annotation is PortalPDFShapeAnnotation
                || annotation is PortalPDFTextAnnotation
                || PortalPDFPressureInkAnnotation.isPressureInk(annotation)
                || annotation.isPortalInkAnnotation
        }

        /**
         SwiftUI에서 선택한 펜 색상과 두께를 PDFView 제스처 환경에 반영합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - color: 펜 도구에 적용할 UIColor 색상입니다.
            - lineWidth: PDF Page 좌표계 기준 펜 굵기입니다.
            - pdfView: 펜 Overlay 상태를 즉시 갱신할 PDFView 입니다.
         */
        func updatePenStyle(
            color: UIColor,
            lineWidth: CGFloat,
            penType: PortalPDFPenType,
            pressureStrength: CGFloat,
            strokeSmoothingStrength: CGFloat,
            highlighterCap: PortalPDFHighlighterCap,
            in pdfView: PDFView
        ) {
            penColor = color
            penLineWidth = max(0.3, lineWidth)
            self.penType = penType
            penPressureStrength = min(2, max(0, pressureStrength))
            penStrokeSmoothingStrength = min(2, max(0, strokeSmoothingStrength))
            self.highlighterCap = highlighterCap
            activePenOverlayLayer?.strokeColor = color.cgColor
            activePenOverlayLayer?.lineWidth = penLineWidth * currentPDFScaleFactor
            activePenOverlayLayer?.setNeedsDisplay()
            scheduleActivePenOverlayRefresh()
        }

        /// SwiftUI에서 선택한 지우개 크기를 PDFView 제스처 환경에 반영합니다.
        func updateEraserSize(_ size: CGFloat) {
            eraserSize = min(max(size, 12), 64)
            guard isEraserPreviewVisible else { return }
            let fallbackPoint = pdfView.map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) } ?? .zero
            updateEraserOverlay(at: lastEraserViewPoint ?? fallbackPoint)
        }

        /// 지우개 상세창이 열리거나 닫힐 때 PDFView의 크기 미리보기를 갱신합니다.
        func updateEraserPreviewVisibility(_ visible: Bool) {
            isEraserPreviewVisible = visible
            guard visible else {
                hideEraserOverlay()
                return
            }
            let fallbackPoint = pdfView.map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) } ?? .zero
            updateEraserOverlay(at: lastEraserViewPoint ?? fallbackPoint)
        }

        /// SwiftUI에서 선택한 도형 종류를 박스 도구에 반영합니다.
        func updateShapeType(_ shapeType: PortalPDFShapeType) {
            selectedShapeType = shapeType
        }

        /// SwiftUI에서 선택한 박스 선·배경 색상을 신규 및 현재 선택 도형에 반영합니다.
        func updateShapeStyle(lineColor: UIColor, fillColor: UIColor, in pdfView: PDFView) {
            shapeLineColor = lineColor
            shapeFillColor = fillColor
            guard let selectedShapeAnnotation else { return }
            let lineChanged = !selectedShapeAnnotation.lineColor.isEqual(lineColor)
            let fillChanged = !selectedShapeAnnotation.fillColor.isEqual(fillColor)
            guard lineChanged || fillChanged else { return }
            selectedShapeAnnotation.lineColor = lineColor
            selectedShapeAnnotation.fillColor = fillColor
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
            onDocumentChanged()
        }

        /**
         SwiftUI에서 전달한 선택 이미지를 현재 PDFView 페이지 중앙에 1회 추가합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - pendingImage: 추가할 이미지 삽입 요청 정보입니다.
            - pdfView: 이미지 주석을 추가할 PDFView 입니다.
         */
        func addPendingImageIfNeeded(_ pendingImage: PortalPDFPendingImage?, in pdfView: PDFView) {
            guard let pendingImage, lastInsertedImageID != pendingImage.id else { return }
            // PDFView가 아직 레이아웃되기 전에는 currentPage가 nil일 수 있습니다.
            // 이 시점에 요청을 소비해 버리면 이후 updateUIView에서도 재시도하지 않아
            // 사진을 골라도 보이지 않는 문제가 발생합니다. 실제 추가에 성공한 뒤에만
            // 요청 ID를 기록해 다음 화면 갱신에서 안전하게 재시도합니다.
            guard addImageAnnotation(
                pendingImage.image,
                animatedGIFData: pendingImage.isAnimatedGIF ? pendingImage.sourceData : nil,
                in: pdfView
            ) else { return }
            lastInsertedImageID = pendingImage.id
            onDocumentChanged()
        }

        /// 선택 이미지에 전달된 크기 초기화·회전·반전·교체·표시 순서 명령을 한 번만 적용합니다.
        func applyPendingImageEditCommandIfNeeded(
            _ command: PortalPDFImageEditCommand?,
            in pdfView: PDFView
        ) {
            guard let command, lastAppliedImageEditCommandID != command.id else { return }
            guard selectedTool == .image,
                  let annotation = selectedImageAnnotation,
                  annotation.isPortalSelected,
                  let page = annotation.page else { return }

            switch command.operation {
            case .replace(let image):
                replaceImageAnnotation(annotation, with: image, on: page, in: pdfView)
            case .applyCrop(let image, let keepsOriginal):
                applyCroppedImageAnnotation(
                    annotation,
                    with: image,
                    keepsOriginal: keepsOriginal,
                    on: page,
                    in: pdfView
                )
            case .resetSize:
                let resetBounds = PortalPDFImageInsertionLayout.bounds(
                    imageSize: annotation.contentImageForEditing.size,
                    viewportSize: pdfView.bounds.size,
                    scaleFactor: pdfView.scaleFactor,
                    pageBounds: page.bounds(for: .cropBox),
                    center: annotation.editingBounds.center
                )
                guard resetBounds.width > 8, resetBounds.height > 8 else { return }
                annotation.editingBounds = resetBounds
                refreshPDFViewAfterAnnotationMutation(in: pdfView)
            case .rotateClockwise:
                // 추가 편집 바의 회전은 선택 박스·핸들·Annotation 위치를 돌리지 않고
                // 박스 안의 이미지 콘텐츠만 시계 방향으로 회전합니다.
                if annotation.animatedGIFData != nil {
                    annotation.rotationAngle += .pi / 2
                    annotation.prepareForPersistence()
                    refreshImageAnnotationPresentation(annotation, on: page)
                } else {
                    replaceImageAnnotation(
                        annotation,
                        with: annotation.clockwiseRotatedContentImage(),
                        on: page,
                        in: pdfView
                    )
                }
            case .flipHorizontal:
                // PDFKit이 기존 Annotation의 렌더 캐시를 유지하지 않도록 새 객체로 교체합니다.
                // 이미지 본문만 반전하고 위치·크기·회전·선택 상태는 그대로 유지합니다.
                replaceImageAnnotation(
                    annotation,
                    with: annotation.contentImageForEditing,
                    horizontalFlip: !annotation.isHorizontallyFlipped,
                    preservesAnimation: true,
                    on: page,
                    in: pdfView
                )
            case .openCropEditor:
                lastAppliedImageEditCommandID = command.id
                onImageCropRequested(annotation.contentImageForEditing)
                return
            case .openSystemEditor:
                lastAppliedImageEditCommandID = command.id
                onSystemImageEditRequested(annotation.contentImageForEditing)
                return
            case .bringToFront:
                page.removeAnnotation(annotation)
                page.addAnnotation(annotation)
                refreshPDFViewAfterAnnotationMutation(in: pdfView)
            case .sendToBack:
                let otherAnnotations = page.annotations.filter { $0 !== annotation }
                page.removeAnnotation(annotation)
                otherAnnotations.forEach { page.removeAnnotation($0) }
                page.addAnnotation(annotation)
                otherAnnotations.forEach { page.addAnnotation($0) }
                refreshPDFViewAfterAnnotationMutation(in: pdfView)
            }
            lastAppliedImageEditCommandID = command.id
            onDocumentChanged()
        }

        /// 선택한 도형을 현재 화면의 PDF 페이지 중앙에 1회 추가하고 즉시 편집 대상으로 선택합니다.
        func addPendingShapeIfNeeded(_ pendingShape: PortalPDFPendingShape?, in pdfView: PDFView) {
            guard let pendingShape, lastInsertedShapeID != pendingShape.id else { return }
            guard addShapeAnnotation(pendingShape.shapeType, in: pdfView) else { return }
            lastInsertedShapeID = pendingShape.id
            onDocumentChanged()
        }

        /// 추가 편집창의 요청을 받아 현재 보이는 페이지 중앙에 텍스트 박스를 한 번만 추가합니다.
        func addPendingTextIfNeeded(
            _ pendingText: PortalPDFPendingText?,
            borderColor: UIColor,
            fillColor: UIColor,
            textColor: UIColor,
            in pdfView: PDFView
        ) {
            guard let pendingText, lastInsertedTextID != pendingText.id else { return }
            let viewCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            guard let page = pdfView.page(for: viewCenter, nearest: true) ?? pdfView.currentPage else { return }
            let pageBounds = page.bounds(for: .cropBox)
            let visibleWidth = min(320, max(160, pdfView.bounds.width * 0.62))
            let visibleHeight = min(96, max(64, pdfView.bounds.height * 0.12))
        var visibleRect = CGRect(
            x: viewCenter.x - visibleWidth / 2,
            y: viewCenter.y - visibleHeight / 2,
            width: visibleWidth,
            height: visibleHeight
        )
        if let toolbarRect = pendingText.occludedViewRect {
            visibleRect = textInsertionRect(
                preferredRect: visibleRect,
                avoiding: toolbarRect,
                in: pdfView.bounds
            )
        }
        let pagePointA = pdfView.convert(visibleRect.origin, to: page)
            let pagePointB = pdfView.convert(
                CGPoint(x: visibleRect.maxX, y: visibleRect.maxY),
                to: page
            )
            let annotationBounds = CGRect(
                x: min(pagePointA.x, pagePointB.x),
                y: min(pagePointA.y, pagePointB.y),
                width: abs(pagePointB.x - pagePointA.x),
                height: abs(pagePointB.y - pagePointA.y)
            ).clampedInside(pageBounds)
            let annotation = PortalPDFTextAnnotation(
                text: "",
                bounds: annotationBounds,
                borderColor: borderColor,
                fillColor: fillColor,
                textColor: textColor
            )
            page.addAnnotation(annotation)
            lastInsertedTextID = pendingText.id
            onDocumentChanged()
        beginTextEditing(annotation, on: page, in: pdfView)
    }

    /// 기본 편집창과 겹치지 않으면서 화면 중앙에 가장 가까운 텍스트 박스 위치를 선택합니다.
    private func textInsertionRect(
        preferredRect: CGRect,
        avoiding occludedRect: CGRect,
        in viewBounds: CGRect
    ) -> CGRect {
        let safeBounds = viewBounds.insetBy(dx: 16, dy: 16)
        let blockedRect = occludedRect.insetBy(dx: -12, dy: -12)
        guard preferredRect.intersects(blockedRect) else {
            return preferredRect
        }

        let halfWidth = preferredRect.width / 2
        let halfHeight = preferredRect.height / 2
        let preferredCenter = CGPoint(x: preferredRect.midX, y: preferredRect.midY)
        let candidateCenters = [
            CGPoint(x: preferredCenter.x, y: blockedRect.minY - halfHeight),
            CGPoint(x: preferredCenter.x, y: blockedRect.maxY + halfHeight),
            CGPoint(x: blockedRect.minX - halfWidth, y: preferredCenter.y),
            CGPoint(x: blockedRect.maxX + halfWidth, y: preferredCenter.y)
        ]
        let candidates = candidateCenters.map { center in
            CGRect(
                x: center.x - halfWidth,
                y: center.y - halfHeight,
                width: preferredRect.width,
                height: preferredRect.height
            )
        }.filter { candidate in
            safeBounds.contains(candidate) && !candidate.intersects(blockedRect)
        }

        return candidates.min { lhs, rhs in
            let lhsDistance = hypot(lhs.midX - preferredCenter.x, lhs.midY - preferredCenter.y)
            let rhsDistance = hypot(rhs.midX - preferredCenter.x, rhs.midY - preferredCenter.y)
            return lhsDistance < rhsDistance
        } ?? preferredRect
    }

        /// 상세 패널의 컬러 변경을 현재 편집 중인 텍스트 박스에 즉시 반영합니다.
        func updateTextStyle(
            borderColor: UIColor,
            fillColor: UIColor,
            textColor: UIColor,
            in pdfView: PDFView
        ) {
            guard let annotation = selectedTextAnnotation else { return }
            let borderChanged = !annotation.borderColor.isEqual(borderColor)
            let fillChanged = !annotation.fillColor.isEqual(fillColor)
            let textChanged = !annotation.textColor.isEqual(textColor)
            guard borderChanged || fillChanged || textChanged else { return }
            annotation.borderColor = borderColor
            annotation.fillColor = fillColor
            annotation.textColor = textColor
            applyActiveTextStyleToEditor()
            pdfView.setNeedsDisplay()
            pdfView.documentView?.setNeedsDisplay()
            onDocumentChanged()
        }

        /**
         펜과 박스 도구의 드래그 제스처를 처리합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - recognizer: PDFView에서 발생한 Pan Gesture 입니다.
         */
        @objc private func handleDrawingPan(_ recognizer: UIPanGestureRecognizer) {
            guard selectedTool == .box || selectedTool == .image || selectedTool == .lasso || selectedTool == .text,
                  let pdfView else { return }
            let viewPoint = recognizer.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
            let pagePoint = pdfView.convert(viewPoint, to: page)

            switch selectedTool {
            case .box:
                handleShapeMoveGesture(recognizer.state, page: page, point: pagePoint)
            case .image:
                // 이미지 위에서 드래그가 시작되면 롱프레스 대기 없이 해당 이미지를
                // 즉시 편집 대상으로 지정하고 같은 Pan에서 바로 이동을 시작합니다.
                if recognizer.state == .began,
                   let imageAnnotation = editableAnnotation(on: page, point: pagePoint) as? PortalPDFImageAnnotation,
                   selectedImageAnnotation !== imageAnnotation || !imageAnnotation.isPortalSelected {
                    selectImageAnnotation(imageAnnotation, in: pdfView)
                }
                handleImageMoveGesture(recognizer.state, page: page, point: pagePoint)
            case .lasso:
                handleLassoGesture(recognizer.state, page: page, point: pagePoint, in: pdfView)
            case .text:
                handleTextTransformGesture(recognizer.state, page: page, point: pagePoint)
            case .handwriting, .pen, .highlighter, .neon, .eraser, .view:
                break
            }
        }

        /// 확정된 올가미 선택 영역이 아닌 곳을 누르면 선택 상태를 즉시 해제합니다.
        @objc private func handleLassoTap(_ recognizer: UITapGestureRecognizer) {
            guard selectedTool == .lasso,
                  recognizer.state == .ended,
                  !selectedLassoAnnotations.isEmpty,
                  let pdfView else { return }
            let viewPoint = recognizer.location(in: pdfView)
            if isLassoDeleteHandleHit(viewPoint, in: pdfView) {
                deleteLassoSelection(in: pdfView)
                return
            }
            guard let page = pdfView.page(for: viewPoint, nearest: false),
                  activeLassoPage === page,
                  selectedLassoBounds != nil else {
                clearLassoSelection()
                return
            }
            let pagePoint = pdfView.convert(viewPoint, to: page)
            if !isPointInsideLassoSelection(pagePoint, padding: 8 / currentPDFScaleFactor) {
                clearLassoSelection()
            }
        }

        /// 이미지·박스·텍스트에 손이 닿는 즉시 해당 객체를 선택하고 편집 도구를 타입에 맞게 전환합니다.
        func handleTextTouchDown(at viewPoint: CGPoint, in pdfView: PDFView) {
            guard selectedTool.supportsDirectObjectSelection else { return }
            if isTextActionMenuHit(viewPoint, in: pdfView)
                || isImageActionMenuHit(viewPoint, in: pdfView) {
                return
            }
            dismissTextActionMenu()
            dismissImageActionMenu()
            guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }

            if let activeTextEditor {
                let editorPoint = activeTextEditor.convert(viewPoint, from: pdfView)
                if activeTextEditor.point(inside: editorPoint, with: nil) {
                    // 현재 입력 중인 박스 내부 터치는 커서·선택 동작을 위해 UITextView에 그대로 전달합니다.
                    return
                }
            }

            let pagePoint = pdfView.convert(viewPoint, to: page)
            guard let annotation = PortalPDFEditableAnnotationHitTesting.topmostSelectableObject(
                in: page.annotations,
                at: pagePoint,
                scaleFactor: currentPDFScaleFactor
            ) else { return }

            if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                activateObjectEditingTool(.image, in: pdfView)
                selectImageAnnotation(imageAnnotation, in: pdfView)
                return
            }
            if let shapeAnnotation = annotation as? PortalPDFShapeAnnotation {
                activateObjectEditingTool(.box, in: pdfView)
                selectShapeAnnotation(shapeAnnotation, in: pdfView)
                return
            }
            guard let textAnnotation = annotation as? PortalPDFTextAnnotation else { return }
            let wasTextTool = selectedTool == .text
            let wasEditingText = activeTextEditor != nil
            if wasEditingText {
                finishTextEditing()
            }
            activateObjectEditingTool(.text, in: pdfView)
            selectTextAnnotation(textAnnotation, in: pdfView)
            if wasEditingText {
                // 다른 텍스트 입력 중 새 박스를 누르면 기존 문구를 저장하고 새 박스로 편집을 이어갑니다.
                beginTextEditing(textAnnotation, on: page, in: pdfView)
            } else if !wasTextTool {
                // 다른 객체 모드에서 텍스트를 선택한 첫 탭은 Text Tap이 시작되지 않았을 수 있으므로
                // 선택과 동시에 작업 메뉴를 표시합니다.
                presentTextActionMenu(for: textAnnotation, on: page, in: pdfView)
            }
        }

        /// 객체 선택 타입에 맞춰 Coordinator와 SwiftUI 기본 편집 도구를 함께 전환합니다.
        func activateObjectEditingTool(_ tool: PortalPDFMarkupTool, in pdfView: PDFView) {
            guard selectedTool.supportsDirectObjectSelection,
                  tool.supportsDirectObjectSelection,
                  selectedTool != tool else { return }
            updateSelectedTool(tool, in: pdfView)
            switch tool {
            case .image:
                onActivateImageTool()
            case .box:
                onActivateShapeTool()
            case .text:
                onActivateTextTool()
            case .view, .handwriting, .pen, .highlighter, .neon, .eraser, .lasso:
                break
            }
        }

        /// 텍스트 도구에서 배경 탭과 터치 종료 상태를 정리합니다.
        @objc private func handleTextTap(_ recognizer: UITapGestureRecognizer) {
            guard selectedTool == .text,
                  recognizer.state == .ended,
                  let pdfView else { return }

            if activeTextEditor != nil {
                finishTextEditing()
                clearSelectedTextAnnotation(in: pdfView)
                return
            }

            let viewPoint = recognizer.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
            let pagePoint = pdfView.convert(viewPoint, to: page)

            if let annotation = textAnnotation(on: page, at: pagePoint) {
                selectTextAnnotation(annotation, in: pdfView)
                presentTextActionMenu(for: annotation, on: page, in: pdfView)
                return
            }
            dismissTextActionMenu()
            clearSelectedTextAnnotation(in: pdfView)
        }

        /// 지정 위치에 있는 최상단 텍스트 박스를 반환합니다.
        func textAnnotation(on page: PDFPage, at point: CGPoint) -> PortalPDFTextAnnotation? {
            page.annotations.reversed().compactMap { $0 as? PortalPDFTextAnnotation }.first { annotation in
                annotation.editingBounds
                    .insetBy(dx: -8 / currentPDFScaleFactor, dy: -8 / currentPDFScaleFactor)
                    .contains(point)
            }
        }

        /// PDFView 좌표가 현재 말풍선 메뉴 내부인지 확인해 메뉴 버튼 터치가 박스 선택으로 전달되지 않게 합니다.
        func isTextActionMenuHit(_ point: CGPoint, in pdfView: PDFView) -> Bool {
            guard let menu = textActionMenuView, let host = menu.superview else { return false }
            let menuPoint = menu.convert(point, from: pdfView)
            return menu.point(inside: menuPoint, with: nil) && host.window != nil
        }

        /// 선택 텍스트 박스 위에 삭제·복제·복사·편집·레이어 순서 메뉴를 표시합니다.
        func presentTextActionMenu(
            for annotation: PortalPDFTextAnnotation,
            on page: PDFPage,
            in pdfView: PDFView
        ) {
            guard activeTextEditor == nil else { return }
            dismissTextActionMenu()

            let host = PortalPDFTextOverlayView(frame: pdfView.bounds)
            host.backgroundColor = .clear
            host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.isUserInteractionEnabled = true
            pdfView.addSubview(host)
            pdfView.bringSubviewToFront(host)

            let menu = PortalPDFTextActionMenuView(frame: .zero)
            menu.onAction = { [weak self, weak annotation, weak page, weak pdfView] action in
                guard let self, let annotation, let page, let pdfView,
                      annotation.page === page else { return }
                self.performTextAction(action, for: annotation, on: page, in: pdfView)
            }
            host.addSubview(menu)
            textActionMenuHostView = host
            textActionMenuView = menu
            textActionMenuAnnotation = annotation
            updateTextActionMenuPosition(in: pdfView)
            animateTextActionMenuPresentation(menu)
        }

        /// 텍스트 작업 말풍선이 선택 박스에서 통통 튀어나오는 것처럼 표시합니다.
        func animateTextActionMenuPresentation(_ menu: PortalPDFTextActionMenuView) {
            menu.alpha = 0
            menu.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
                .translatedBy(x: 0, y: menu.showsTailAtTop ? -6 : 6)
            let animations = {
                menu.alpha = 1
                menu.transform = .identity
            }
            guard !UIAccessibility.isReduceMotionEnabled else {
                UIView.animate(withDuration: 0.16, animations: animations)
                return
            }
            UIView.animate(
                withDuration: 0.42,
                delay: 0,
                usingSpringWithDamping: 0.58,
                initialSpringVelocity: 0.9,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
                animations: animations
            )
        }

        /// 현재 확대·이동 상태에서 메뉴를 선택 박스 상단 중앙에 배치하고 공간이 없으면 아래로 전환합니다.
        func updateTextActionMenuPosition(in pdfView: PDFView) {
            guard let menu = textActionMenuView,
                  let annotation = textActionMenuAnnotation,
                  let page = annotation.page else { return }
            let textRect = pdfView.convert(annotation.editingBounds, from: page).standardized
            let horizontalMargin: CGFloat = 12
            let menuSize = CGSize(
                width: min(420, max(300, pdfView.bounds.width - horizontalMargin * 2)),
                height: 64
            )
            let minimumX = pdfView.bounds.minX + horizontalMargin
            let maximumX = pdfView.bounds.maxX - horizontalMargin - menuSize.width
            let centeredX = textRect.midX - menuSize.width / 2
            let x = min(max(centeredX, minimumX), max(minimumX, maximumX))
            let topLimit = pdfView.bounds.minY + pdfView.safeAreaInsets.top + 8
            let proposedAboveY = textRect.minY - menuSize.height - 10
            let showBelow = proposedAboveY < topLimit
            let y = showBelow ? textRect.maxY + 10 : proposedAboveY
            menu.showsTailAtTop = showBelow
            menu.frame = CGRect(origin: CGPoint(x: x, y: y), size: menuSize)
        }

        /// 말풍선 메뉴와 투명 터치 호스트를 함께 제거합니다.
        func dismissTextActionMenu() {
            let menu = textActionMenuView
            let host = textActionMenuHostView
            textActionMenuView = nil
            textActionMenuHostView = nil
            textActionMenuAnnotation = nil
            host?.isUserInteractionEnabled = false
            guard let menu, let host else {
                menu?.removeFromSuperview()
                host?.removeFromSuperview()
                return
            }
            let removeViews = {
                menu.removeFromSuperview()
                host.removeFromSuperview()
            }
            guard !UIAccessibility.isReduceMotionEnabled else {
                UIView.animate(withDuration: 0.14, animations: { menu.alpha = 0 }) { _ in removeViews() }
                return
            }
            UIView.animateKeyframes(
                withDuration: 0.24,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .calculationModeCubic],
                animations: {
                    UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.32) {
                        menu.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
                    }
                    UIView.addKeyframe(withRelativeStartTime: 0.28, relativeDuration: 0.72) {
                        menu.alpha = 0
                        menu.transform = CGAffineTransform(scaleX: 0.74, y: 0.74)
                    }
                },
                completion: { _ in removeViews() }
            )
        }

        /// PDFView 좌표가 이미지 말풍선 메뉴 내부인지 확인합니다.
        func isImageActionMenuHit(_ point: CGPoint, in pdfView: PDFView) -> Bool {
            guard let menu = imageActionMenuView, let host = menu.superview else { return false }
            let menuPoint = menu.convert(point, from: pdfView)
            return menu.point(inside: menuPoint, with: nil) && host.window != nil
        }

        /// 선택 이미지 위에 변경·회전·반전·시스템 편집·레이어 순서 메뉴를 표시합니다.
        func presentImageActionMenu(for annotation: PortalPDFImageAnnotation, in pdfView: PDFView) {
            guard selectedTool == .image,
                  annotation.isPortalSelected,
                  annotation.page != nil else { return }
            if imageActionMenuAnnotation === annotation, imageActionMenuView != nil {
                updateImageActionMenuPosition(in: pdfView)
                return
            }
            dismissImageActionMenu()

            let host = PortalPDFTextOverlayView(frame: pdfView.bounds)
            host.backgroundColor = .clear
            host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.isUserInteractionEnabled = true
            pdfView.addSubview(host)
            pdfView.bringSubviewToFront(host)

            let menu = PortalPDFImageActionMenuView(frame: .zero)
            menu.onAction = { [weak self, weak annotation] action in
                guard let self,
                      let annotation,
                      annotation === self.selectedImageAnnotation,
                      annotation.isPortalSelected else { return }
                self.dismissImageActionMenu()
                self.onImageActionRequested(action)
            }
            host.addSubview(menu)
            imageActionMenuHostView = host
            imageActionMenuView = menu
            imageActionMenuAnnotation = annotation
            updateImageActionMenuPosition(in: pdfView)
            animateImageActionMenuPresentation(menu)
        }

        /// 이미지 편집 말풍선이 선택 이미지에서 통통 튀어나오는 것처럼 표시합니다.
        func animateImageActionMenuPresentation(_ menu: PortalPDFImageActionMenuView) {
            menu.alpha = 0
            menu.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
                .translatedBy(x: 0, y: menu.showsTailAtTop ? -6 : 6)
            let animations = {
                menu.alpha = 1
                menu.transform = .identity
            }
            guard !UIAccessibility.isReduceMotionEnabled else {
                UIView.animate(withDuration: 0.16, animations: animations)
                return
            }
            UIView.animate(
                withDuration: 0.42,
                delay: 0,
                usingSpringWithDamping: 0.58,
                initialSpringVelocity: 0.9,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
                animations: animations
            )
        }

        /// 현재 확대·이동 상태에서 이미지 말풍선을 선택 이미지 상단 중앙에 배치합니다.
        func updateImageActionMenuPosition(in pdfView: PDFView) {
            guard let menu = imageActionMenuView,
                  let annotation = imageActionMenuAnnotation,
                  let page = annotation.page else { return }
            let imageRect = pdfView.convert(annotation.editingBounds, from: page).standardized
            let horizontalMargin: CGFloat = 12
            let menuSize = CGSize(
                width: min(420, max(300, pdfView.bounds.width - horizontalMargin * 2)),
                height: 64
            )
            let minimumX = pdfView.bounds.minX + horizontalMargin
            let maximumX = pdfView.bounds.maxX - horizontalMargin - menuSize.width
            let centeredX = imageRect.midX - menuSize.width / 2
            let x = min(max(centeredX, minimumX), max(minimumX, maximumX))
            let topLimit = pdfView.bounds.minY + pdfView.safeAreaInsets.top + 8
            let proposedAboveY = imageRect.minY - menuSize.height - 10
            let showBelow = proposedAboveY < topLimit
            let y = showBelow ? imageRect.maxY + 10 : proposedAboveY
            menu.showsTailAtTop = showBelow
            menu.frame = CGRect(origin: CGPoint(x: x, y: y), size: menuSize)
        }

        /// 이미지 말풍선 메뉴와 투명 터치 호스트를 함께 제거합니다.
        func dismissImageActionMenu() {
            let menu = imageActionMenuView
            let host = imageActionMenuHostView
            imageActionMenuView = nil
            imageActionMenuHostView = nil
            imageActionMenuAnnotation = nil
            host?.isUserInteractionEnabled = false
            guard let menu, let host else {
                menu?.removeFromSuperview()
                host?.removeFromSuperview()
                return
            }
            let removeViews = {
                menu.removeFromSuperview()
                host.removeFromSuperview()
            }
            guard !UIAccessibility.isReduceMotionEnabled else {
                UIView.animate(withDuration: 0.14, animations: { menu.alpha = 0 }) { _ in removeViews() }
                return
            }
            UIView.animateKeyframes(
                withDuration: 0.24,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .calculationModeCubic],
                animations: {
                    UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.32) {
                        menu.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
                    }
                    UIView.addKeyframe(withRelativeStartTime: 0.28, relativeDuration: 0.72) {
                        menu.alpha = 0
                        menu.transform = CGAffineTransform(scaleX: 0.74, y: 0.74)
                    }
                },
                completion: { _ in removeViews() }
            )
        }

        /// 말풍선에서 선택한 텍스트 박스 명령을 실행합니다.
        func performTextAction(
            _ action: PortalPDFTextActionMenuView.Action,
            for annotation: PortalPDFTextAnnotation,
            on page: PDFPage,
            in pdfView: PDFView
        ) {
            dismissTextActionMenu()
            switch action {
            case .delete:
                deleteTextAnnotation(annotation, from: page, in: pdfView)
            case .duplicate:
                duplicateTextAnnotation(annotation, on: page, in: pdfView)
            case .copy:
                UIPasteboard.general.string = annotation.attributedText.string
            case .edit:
                selectTextAnnotation(annotation, in: pdfView)
                beginTextEditing(annotation, on: page, in: pdfView)
            case .bringToFront:
                page.removeAnnotation(annotation)
                page.addAnnotation(annotation)
                selectTextAnnotation(annotation, in: pdfView)
                refreshPDFViewAfterAnnotationMutation(in: pdfView)
                onDocumentChanged()
            case .sendToBack:
                let otherAnnotations = page.annotations.filter { $0 !== annotation }
                page.removeAnnotation(annotation)
                otherAnnotations.forEach { page.removeAnnotation($0) }
                page.addAnnotation(annotation)
                otherAnnotations.forEach { page.addAnnotation($0) }
                selectTextAnnotation(annotation, in: pdfView)
                refreshPDFViewAfterAnnotationMutation(in: pdfView)
                onDocumentChanged()
            }
        }

        /// 선택 텍스트 박스의 내용·서식·링크를 유지한 복제본을 살짝 이동해 생성합니다.
        func duplicateTextAnnotation(
            _ annotation: PortalPDFTextAnnotation,
            on page: PDFPage,
            in pdfView: PDFView
        ) {
            let pageBounds = page.bounds(for: .cropBox)
            let duplicatedBounds = annotation.editingBounds
                .offsetBy(dx: 16, dy: -16)
                .clampedInside(pageBounds)
            let duplicate = PortalPDFTextAnnotation(
                text: annotation.text,
                bounds: duplicatedBounds,
                borderColor: annotation.borderColor,
                fillColor: annotation.fillColor,
                textColor: annotation.textColor
            )
            duplicate.fontName = annotation.fontName
            duplicate.fontSize = annotation.fontSize
            duplicate.isBold = annotation.isBold
            duplicate.isItalic = annotation.isItalic
            duplicate.isUnderlined = annotation.isUnderlined
            duplicate.isStruckThrough = annotation.isStruckThrough
            duplicate.alignment = annotation.alignment
            duplicate.linkURL = annotation.linkURL
            duplicate.setAttributedText(annotation.attributedText)
            duplicate.prepareForPersistence()
            page.addAnnotation(duplicate)
            if duplicate.linkURL != nil {
                syncTextLink(for: duplicate)
            }
            selectTextAnnotation(duplicate, in: pdfView)
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
            onDocumentChanged()
        }

        /// 선택 텍스트의 왼쪽 상단 삭제 버튼을 이미지 삭제 버튼과 동일하게 전용 탭으로 처리합니다.
        @objc private func handleSelectedTextDeleteTap(_ recognizer: UITapGestureRecognizer) {
            guard selectedTool == .text,
                  recognizer.state == .ended,
                  activeTextEditor == nil,
                  let pdfView,
                  let annotation = selectedTextAnnotation,
                  annotation.isPortalTextSelected,
                  let page = annotation.page else { return }
            let viewPoint = recognizer.location(in: pdfView)
            let pagePoint = pdfView.convert(viewPoint, to: page)
            guard annotation.isDeleteHandleHit(pagePoint, scaleFactor: currentPDFScaleFactor) else { return }
            deleteTextAnnotation(annotation, from: page, in: pdfView)
        }

        /// 첫 번째 탭으로 활성화된 텍스트 박스만 길게 눌렀을 때 편집기로 전환합니다.
        @objc private func handleTextLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard selectedTool == .text,
                  recognizer.state == .began,
                  activeTextEditor == nil,
                  let pdfView,
                  let annotation = selectedTextAnnotation,
                  let page = annotation.page else { return }
            let viewPoint = recognizer.location(in: pdfView)
            let pagePoint = pdfView.convert(viewPoint, to: page)
            guard annotation.editingBounds
                .insetBy(dx: -8 / currentPDFScaleFactor, dy: -8 / currentPDFScaleFactor)
                .contains(pagePoint) else { return }
            beginTextEditing(annotation, on: page, in: pdfView)
        }

        func selectTextAnnotation(_ annotation: PortalPDFTextAnnotation, in pdfView: PDFView) {
            // 실제 UITextView 편집 종료 과정에서는 같은 Annotation 참조를 유지한 채
            // 화면 선택 표시만 해제될 수 있습니다. 이 상태에서 동일 박스를 다시 누르면
            // 참조 동일성만으로 조기 종료하지 말고 선택 상태와 PDFKit 타일을 복원합니다.
            if selectedTextAnnotation === annotation {
                guard !annotation.isPortalTextSelected else { return }
                annotation.isPortalTextSelected = true
                annotation.updateEditingDisplayScaleFactor(currentPDFScaleFactor)
                if let page = annotation.page {
                    refreshPortalAnnotationTiles([(page, annotation)], in: pdfView)
                }
                return
            }
            var affected: [(PDFPage, PDFAnnotation)] = []
            if let previous = selectedTextAnnotation, let previousPage = previous.page {
                previous.isPortalTextSelected = false
                affected.append((previousPage, previous))
            }
            annotation.isPortalTextSelected = true
            annotation.updateEditingDisplayScaleFactor(currentPDFScaleFactor)
            selectedTextAnnotation = annotation
            if let page = annotation.page {
                affected.append((page, annotation))
            }
            refreshPortalAnnotationTiles(affected, in: pdfView)
        }

        func clearSelectedTextAnnotation(in pdfView: PDFView) {
            dismissTextActionMenu()
            guard activeTextEditor == nil,
                  let annotation = selectedTextAnnotation else { return }
            let page = annotation.page
            annotation.isPortalTextSelected = false
            selectedTextAnnotation = nil
            if let page {
                refreshPortalAnnotationTiles([(page, annotation)], in: pdfView)
            }
        }

        /// 활성화된 텍스트 박스를 이동하거나 8방향 조절점으로 크기를 변경합니다.
        func handleTextTransformGesture(
            _ state: UIGestureRecognizer.State,
            page: PDFPage,
            point: CGPoint
        ) {
            guard activeTextEditor == nil,
                  let annotation = selectedTextAnnotation,
                  annotation.page === page,
                  annotation.isPortalTextSelected else {
                activeImageDragState = nil
                return
            }

            switch state {
            case .began:
                dismissTextActionMenu()
                if let handle = annotation.resizeHandle(at: point, scaleFactor: currentPDFScaleFactor) {
                    activeImageDragState = .resizingBounds(
                        handle: handle,
                        initialBounds: annotation.editingBounds,
                        initialPoint: point
                    )
                } else if annotation.editingBounds
                    .insetBy(dx: -18 / currentPDFScaleFactor, dy: -18 / currentPDFScaleFactor)
                    .contains(point) {
                    activeImageDragState = .moving(previousPoint: point)
                } else {
                    activeImageDragState = nil
                }
            case .changed:
                switch activeImageDragState {
                case .moving(let previousPoint):
                    let delta = CGPoint(x: point.x - previousPoint.x, y: point.y - previousPoint.y)
                    annotation.editingBounds = annotation.editingBounds
                        .offsetBy(dx: delta.x, dy: delta.y)
                        .clampedInside(page.bounds(for: .cropBox))
                    activeImageDragState = .moving(previousPoint: point)
                case .transforming:
                    activeImageDragState = nil
                case .resizingBounds(let handle, let initialBounds, let initialPoint):
                    annotation.editingBounds = resizedEditingBounds(
                        handle: handle,
                        initialBounds: initialBounds,
                        initialPoint: initialPoint,
                        currentPoint: point,
                        rotationAngle: 0
                    ).clampedInside(page.bounds(for: .cropBox))
                case nil:
                    break
                }
                if let pdfView {
                    // PDFAnnotation.bounds만 변경하면 PDFKit의 화면 타일과 주석 위치 캐시가
                    // 이전 좌표를 계속 사용할 수 있습니다. 텍스트 박스 한 개만 다시 등록해
                    // 드래그 중 새 위치가 즉시 보이도록 하고, 문서 전체 재렌더링은 피합니다.
                    refreshPortalAnnotationTiles([(page, annotation)], in: pdfView)
                    pdfView.documentView?.setNeedsDisplay()
                }
            case .ended:
                activeImageDragState = nil
                annotation.prepareForPersistence()
                if let pdfView {
                    // 마지막 이동 좌표를 PDFKit 타일 캐시에도 확정하여 다음 탭이나 확대·축소가
                    // 발생하기 전까지 이전 위치의 선택선이 남지 않도록 합니다.
                    refreshPortalAnnotationTiles([(page, annotation)], in: pdfView)
                }
                onDocumentChanged()
            case .cancelled, .failed:
                activeImageDragState = nil
            default:
                break
            }
        }

        func deleteTextAnnotation(
            _ annotation: PortalPDFTextAnnotation,
            from page: PDFPage,
            in pdfView: PDFView
        ) {
            dismissTextActionMenu()
            annotation.isPortalTextSelected = false
            selectedTextAnnotation = nil
            activeImageDragState = nil
            annotation.shouldDisplay = false
            annotation.shouldPrint = false
            page.removeAnnotation(annotation)
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
            onDocumentChanged()
        }

        /// PDF 텍스트 Annotation 위에 UIKit 입력기를 겹치고 키보드 상단 어시스트를 연결합니다.
        func beginTextEditing(_ annotation: PortalPDFTextAnnotation, on page: PDFPage, in pdfView: PDFView) {
            dismissTextActionMenu()
            if selectedTextAnnotation !== annotation {
                finishTextEditing()
            }
            guard activeTextEditor == nil else {
                activeTextEditor?.becomeFirstResponder()
                return
            }

            let editor = PortalPDFTextEditorView(frame: .zero)
            editor.delegate = self
            editor.isScrollEnabled = true
            editor.isEditable = true
            editor.isSelectable = true
            editor.isUserInteractionEnabled = true
            editor.delaysContentTouches = false
            editor.canCancelContentTouches = true
            editor.keyboardDismissMode = .none
            editor.panGestureRecognizer.minimumNumberOfTouches = 1
            editor.panGestureRecognizer.maximumNumberOfTouches = 1
            editor.textDragInteraction?.isEnabled = true
            editor.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            editor.textContainer.lineFragmentPadding = 0
            editor.autocorrectionType = .yes
            editor.spellCheckingType = .yes
            editor.smartDashesType = .yes
            editor.smartQuotesType = .yes
            editor.layer.cornerRadius = 6
            editor.layer.masksToBounds = true
            editor.portalAccessoryView = makeTextAssistantView()
            selectedTextAnnotation = annotation
            activeTextEditor = editor
            activeTextEditorDisplayScale = max(currentPDFScaleFactor, 0.01)
            (pdfView as? PortalPDFView)?.protectedTextInputView = editor
            annotation.isPortalTextEditing = true
            // 커스텀 편집 플래그만 변경하면 PDFKit이 이전 주석 타일을 재사용할 수 있습니다.
            // 편집 시작 시 주석 타일을 다시 등록해 PDF 문구와 UIKit 입력기가 중복 표시되지 않게 합니다.
            refreshPortalAnnotationTiles([(page, annotation)], in: pdfView)
            applyActiveTextStyleToEditor()
            // 입력기는 최상위 PDFView가 아니라 실제 PDF 페이지 오버레이에만 추가합니다.
            // 따라서 확대·이동 중에도 페이지 밖이나 기본 편집 툴 위로 떠다니지 않습니다.
            guard let editorContainer = textEditorContainer(for: page, in: pdfView) else { return }
            editorContainer.isUserInteractionEnabled = true
            editorContainer.addSubview(editor)
            let frameInPDFView = pdfView.convert(annotation.editingBounds, from: page).standardized
            editor.frame = editorContainer.convert(frameInPDFView, from: pdfView).standardized
            // 이후 SwiftUI 도구 상태가 다시 반영되더라도 편집 중 PDF 탭은 사용하지 않습니다.
            textTapGesture?.isEnabled = true
            textTouchDownGesture?.isEnabled = true
            textDeleteTapGesture?.isEnabled = false
            textLongPressGesture?.isEnabled = false
            suspendPDFBackgroundInteractions(in: pdfView, preserving: editor)
            beginTextKeyboardObservation()
            DispatchQueue.main.async { [weak self, weak editor] in
                editor?.becomeFirstResponder()
                if let editor {
                    self?.restoreNativeTextEditorGestures(editor)
                }
                self?.keepActiveTextEditorVisible()
            }
        }

        /// PDF 편집 제스처 일괄 처리에서 과거에 비활성화된 UITextView 기본 인식기를 복구합니다.
        func restoreNativeTextEditorGestures(_ editor: PortalPDFTextEditorView) {
            editor.isEditable = true
            editor.isSelectable = true
            editor.isUserInteractionEnabled = true
            editor.panGestureRecognizer.minimumNumberOfTouches = 1
            editor.panGestureRecognizer.maximumNumberOfTouches = 1
            editor.portalDescendantGestureRecognizers.forEach { recognizer in
                editingDisabledDocumentGestures.remove(recognizer)
                if !recognizer.isEnabled {
                    recognizer.isEnabled = true
                }
            }
        }

        /// 텍스트 입력기와 PDF의 두 손가락 이동·확대는 유지하고 한 손가락 배경 동작만 중단합니다.
        func suspendPDFBackgroundInteractions(
            in pdfView: PDFView,
            preserving editor: PortalPDFTextEditorView
        ) {
            restorePDFBackgroundInteractions()
            // 한 장씩 보기에서는 페이지 전환용 ScrollView와 실제 문서 이동용 ScrollView가
            // 함께 있으므로 documentView의 조상인 실제 뷰포트만 두 손가락 이동 대상으로 둡니다.
            let documentScrollView = viewportScrollView(in: pdfView)
            let documentPanGesture = documentScrollView?.panGestureRecognizer
            textEditingDocumentScrollView = documentScrollView
            suspendedKeyboardDismissMode = documentScrollView?.keyboardDismissMode
            suspendedScrollDelaysContentTouches = documentScrollView?.delaysContentTouches
            documentScrollView?.keyboardDismissMode = .none
            // 상위 PDF 스크롤이 두 번째 손가락을 기다리며 첫 터치를 지연하면
            // UITextView의 커서 이동·선택·드래그가 시작되지 않습니다.
            // 취소 동작은 유지해 두 손가락이 들어오면 PDF 이동·확대로 전환합니다.
            documentScrollView?.delaysContentTouches = false
            suspendedPDFGestureStates = pdfView.portalDescendantGestureRecognizers.compactMap { recognizer -> SuspendedPDFGestureState? in
                // 다른 텍스트 박스 터치 전환은 2단계 입력 중에도 계속 감지해야 합니다.
                if recognizer === textTouchDownGesture {
                    recognizer.isEnabled = true
                    return nil
                }
                guard let gestureView = recognizer.view,
                      gestureView !== editor,
                      !gestureView.isDescendant(of: editor) else { return nil }

                let originalState = SuspendedPDFGestureState(
                    recognizer: recognizer,
                    wasEnabled: recognizer.isEnabled,
                    minimumTouches: (recognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches,
                    maximumTouches: (recognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches
                )

                // PDFKit은 보기 방식에 따라 확대 인식기를 여러 계층에 둘 수 있습니다.
                // Pinch는 원래 PDFKit 설정 그대로 유지합니다.
                if recognizer is UIPinchGestureRecognizer {
                    recognizer.isEnabled = originalState.wasEnabled
                    return originalState
                }

                if recognizer === documentPanGesture,
                   let panGesture = recognizer as? UIPanGestureRecognizer {
                    recognizer.isEnabled = true
                    panGesture.minimumNumberOfTouches = 2
                    panGesture.maximumNumberOfTouches = 2
                    return originalState
                }

                recognizer.isEnabled = false
                return originalState
            }
        }

        /// 텍스트 편집 시작 전에 PDFView가 사용하던 제스처 활성화 상태를 정확히 복원합니다.
        func restorePDFBackgroundInteractions() {
            suspendedPDFGestureStates.forEach { state in
                state.recognizer.isEnabled = state.wasEnabled
                if let panGesture = state.recognizer as? UIPanGestureRecognizer {
                    if let minimumTouches = state.minimumTouches {
                        panGesture.minimumNumberOfTouches = minimumTouches
                    }
                    if let maximumTouches = state.maximumTouches {
                        panGesture.maximumNumberOfTouches = maximumTouches
                    }
                }
            }
            suspendedPDFGestureStates.removeAll()
            if let suspendedKeyboardDismissMode {
                textEditingDocumentScrollView?.keyboardDismissMode = suspendedKeyboardDismissMode
            }
            if let suspendedScrollDelaysContentTouches {
                textEditingDocumentScrollView?.delaysContentTouches = suspendedScrollDelaysContentTouches
            }
            suspendedKeyboardDismissMode = nil
            suspendedScrollDelaysContentTouches = nil
            textEditingDocumentScrollView = nil
        }

        /// 키보드 프레임이 확정될 때마다 현재 문자 박스가 키보드와 어시스트바 위에 있도록 이동합니다.
        func beginTextKeyboardObservation() {
            if let textKeyboardObserver {
                NotificationCenter.default.removeObserver(textKeyboardObserver)
            }
            textKeyboardObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.keepActiveTextEditorVisible(notification)
            }
        }

        func keepActiveTextEditorVisible(_ notification: Notification? = nil) {
            guard let pdfView,
                  let editor = activeTextEditor,
                  let annotation = selectedTextAnnotation,
                  let page = annotation.page else { return }
            let keyboardFrame = (notification?.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                ?? CGRect(x: 0, y: pdfView.window?.bounds.height ?? pdfView.bounds.height, width: pdfView.bounds.width, height: 0)
            let keyboardFrameInPDFView = pdfView.convert(keyboardFrame, from: nil)
            guard keyboardFrameInPDFView.minY < pdfView.bounds.maxY else { return }
            let accessoryHeight = editor.portalAccessoryView?.bounds.height ?? 54
            let visibleBottom = keyboardFrameInPDFView.minY - accessoryHeight - 12
            let currentFrame = pdfView.convert(annotation.editingBounds, from: page).standardized
            let coveredHeight = currentFrame.maxY - visibleBottom
            guard coveredHeight > 0,
                  let scrollView = pdfContentScrollView(in: pdfView) else { return }
            let proposedOffset = CGPoint(
                x: scrollView.contentOffset.x,
                y: scrollView.contentOffset.y + coveredHeight
            )
            scrollView.setContentOffset(clampedContentOffset(proposedOffset, in: scrollView), animated: false)
            pdfView.layoutIfNeeded()
            let frameInPDFView = pdfView.convert(annotation.editingBounds, from: page).standardized
            if let editorContainer = editor.superview {
                editor.frame = editorContainer.convert(frameInPDFView, from: pdfView).standardized
            }
        }

        func pdfContentScrollView(in rootView: UIView) -> UIScrollView? {
            for subview in rootView.subviews where subview !== activeTextEditor {
                if let scrollView = subview as? UIScrollView { return scrollView }
                if let scrollView = pdfContentScrollView(in: subview) { return scrollView }
            }
            return nil
        }

        /// 웹 입력 어시스트의 텍스트 관련 기능을 동일한 순서의 가로 스크롤 바로 제공합니다.
        func makeTextAssistantView() -> UIView {
            let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
            effectView.frame.size.height = 54
            let scrollView = UIScrollView()
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.alwaysBounceHorizontal = true
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            let stackView = UIStackView()
            stackView.axis = .horizontal
            stackView.alignment = .center
            stackView.spacing = 6
            stackView.translatesAutoresizingMaskIntoConstraints = false
            effectView.contentView.addSubview(scrollView)
            scrollView.addSubview(stackView)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 8),
                scrollView.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
                stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            ])

            func button(_ systemName: String, label: String, action: @escaping () -> Void) -> UIButton {
                let control = UIButton(type: .system)
                control.setImage(UIImage(systemName: systemName), for: .normal)
                control.tintColor = .white
                control.backgroundColor = UIColor.white.withAlphaComponent(0.11)
                control.layer.cornerRadius = 16
                control.accessibilityLabel = label
                control.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    control.widthAnchor.constraint(equalToConstant: 38),
                    control.heightAnchor.constraint(equalToConstant: 38),
                ])
                control.addAction(UIAction { _ in action() }, for: .touchUpInside)
                return control
            }

            func menuButton(_ systemName: String, label: String, menu: UIMenu) -> UIButton {
                let control = button(systemName, label: label) {}
                control.menu = menu
                control.showsMenuAsPrimaryAction = true
                return control
            }

            let palette: [(String, UIColor)] = [
                ("검정", .black), ("흰색", .white), ("빨강", .systemRed), ("주황", .systemOrange),
                ("노랑", .systemYellow), ("초록", .systemGreen), ("파랑", .systemBlue), ("보라", .systemPurple),
            ]
            func colorMenu(_ title: String, apply: @escaping (UIColor) -> Void, includesClear: Bool = false) -> UIMenu {
                var actions = palette.map { name, color in
                    UIAction(
                        title: name,
                        image: UIImage(systemName: "circle.fill")?.withTintColor(color, renderingMode: .alwaysOriginal)
                    ) { _ in apply(color) }
                }
                if includesClear {
                    actions.insert(UIAction(title: "투명", image: UIImage(systemName: "circle.slash")) { _ in
                        apply(.clear)
                    }, at: 0)
                }
                return UIMenu(title: title, options: .displayInline, children: actions)
            }

            stackView.addArrangedSubview(button("arrow.uturn.backward", label: "텍스트 실행 취소") { [weak self] in
                self?.activeTextEditor?.undoManager?.undo()
            })
            stackView.addArrangedSubview(button("arrow.uturn.forward", label: "텍스트 다시 실행") { [weak self] in
                self?.activeTextEditor?.undoManager?.redo()
            })
            stackView.addArrangedSubview(button("textformat", label: "서체 변경") { [weak self] in
                self?.presentTextFontPicker()
            })
            stackView.addArrangedSubview(button("minus", label: "글자 크기 1 감소") { [weak self] in
                self?.changeActiveTextFontSize(by: -1)
            })
            stackView.addArrangedSubview(button("plus", label: "글자 크기 1 증가") { [weak self] in
                self?.changeActiveTextFontSize(by: 1)
            })
            stackView.addArrangedSubview(button("bold", label: "굵게") { [weak self] in
                self?.toggleActiveTextTrait(.traitBold)
            })
            stackView.addArrangedSubview(button("italic", label: "기울임") { [weak self] in
                self?.toggleActiveTextTrait(.traitItalic)
            })
            stackView.addArrangedSubview(button("underline", label: "밑줄") { [weak self] in
                self?.toggleActiveTextDecoration(.underlineStyle)
            })
            stackView.addArrangedSubview(button("strikethrough", label: "취소선") { [weak self] in
                self?.toggleActiveTextDecoration(.strikethroughStyle)
            })
            stackView.addArrangedSubview(menuButton(
                "paintpalette",
                label: "글자 색상",
                menu: colorMenu("글자 색상") { [weak self] color in
                    self?.changeActiveTextColor(color)
                }
            ))
            stackView.addArrangedSubview(menuButton(
                "paintbrush",
                label: "배경 색상",
                menu: colorMenu("배경 색상", apply: { [weak self] color in
                    self?.updateActiveTextStyle { $0.fillColor = color }
                }, includesClear: true)
            ))
            stackView.addArrangedSubview(menuButton(
                "square",
                label: "테두리 색상",
                menu: colorMenu("테두리 색상", apply: { [weak self] color in
                    self?.updateActiveTextStyle { $0.borderColor = color }
                }, includesClear: true)
            ))
            let alignmentMenu = UIMenu(title: "문구 정렬", options: .displayInline, children: [
                UIAction(title: "왼쪽", image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                    self?.updateActiveTextStyle { $0.alignment = .left }
                },
                UIAction(title: "가운데", image: UIImage(systemName: "text.aligncenter")) { [weak self] _ in
                    self?.updateActiveTextStyle { $0.alignment = .center }
                },
                UIAction(title: "오른쪽", image: UIImage(systemName: "text.alignright")) { [weak self] _ in
                    self?.updateActiveTextStyle { $0.alignment = .right }
                },
            ])
            stackView.addArrangedSubview(menuButton("text.alignleft", label: "문구 정렬", menu: alignmentMenu))
            stackView.addArrangedSubview(button("link", label: "URL 링크 적용") { [weak self] in
                self?.toggleActiveTextLink()
            })
            let dismissKeyboardButton = button(
                "keyboard.chevron.compact.down",
                label: "키보드 내리기"
            ) { [weak self] in
                self?.activeTextEditor?.resignFirstResponder()
            }
            effectView.contentView.addSubview(dismissKeyboardButton)
            NSLayoutConstraint.activate([
                dismissKeyboardButton.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -8),
                dismissKeyboardButton.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),
                scrollView.trailingAnchor.constraint(equalTo: dismissKeyboardButton.leadingAnchor, constant: -8),
            ])
            return effectView
        }

        func updateActiveTextStyle(_ mutation: (PortalPDFTextAnnotation) -> Void) {
            guard let annotation = selectedTextAnnotation else { return }
            mutation(annotation)
            annotation.prepareForPersistence()
            applyActiveTextStyleToEditor()
            documentChangedHandler()
        }

        /// 선택 범위가 있으면 해당 문구만, 커서만 있으면 이후 입력 문자에만 서식을 적용합니다.
        func mutateActiveInlineText(
            selectedMutation: (NSMutableAttributedString, NSRange) -> Void,
            typingMutation: (inout [NSAttributedString.Key: Any]) -> Void
        ) {
            guard let annotation = selectedTextAnnotation,
                  let editor = activeTextEditor else { return }
            let selection = editor.selectedRange
            let currentText = editor.attributedText ?? NSAttributedString(string: editor.text ?? "")
            if selection.location != NSNotFound, selection.length > 0,
               NSMaxRange(selection) <= currentText.length {
                let mutableText = NSMutableAttributedString(attributedString: currentText)
                selectedMutation(mutableText, selection)
                editor.attributedText = mutableText
                editor.selectedRange = selection
                annotation.setAttributedText(annotationText(from: mutableText))
            } else {
                var typingAttributes = editor.typingAttributes
                typingMutation(&typingAttributes)
                editor.typingAttributes = typingAttributes
            }
            annotation.prepareForPersistence()
            documentChangedHandler()
        }

        func font(_ font: UIFont, setting trait: UIFontDescriptor.SymbolicTraits, enabled: Bool) -> UIFont {
            var traits = font.fontDescriptor.symbolicTraits
            if enabled {
                traits.insert(trait)
            } else {
                traits.remove(trait)
            }
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }

        func toggleActiveTextTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
            guard let editor = activeTextEditor else { return }
            let selection = editor.selectedRange
            let selectedText = editor.attributedText ?? NSAttributedString(string: editor.text ?? "")
            var allEnabled = selection.length > 0
            if selection.length > 0, NSMaxRange(selection) <= selectedText.length {
                selectedText.enumerateAttribute(.font, in: selection) { value, _, stop in
                    guard let font = value as? UIFont,
                          font.fontDescriptor.symbolicTraits.contains(trait) else {
                        allEnabled = false
                        stop.pointee = true
                        return
                    }
                }
            } else {
                let typingFont = editor.typingAttributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 16)
                allEnabled = typingFont.fontDescriptor.symbolicTraits.contains(trait)
            }
            let shouldEnable = !allEnabled
            mutateActiveInlineText { text, range in
                text.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let currentFont = value as? UIFont ?? UIFont.systemFont(ofSize: 16)
                    text.addAttribute(.font, value: self.font(currentFont, setting: trait, enabled: shouldEnable), range: subrange)
                }
            } typingMutation: { attributes in
                let currentFont = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 16)
                attributes[.font] = self.font(currentFont, setting: trait, enabled: shouldEnable)
            }
        }

        func toggleActiveTextDecoration(_ key: NSAttributedString.Key) {
            guard let editor = activeTextEditor else { return }
            let selection = editor.selectedRange
            let currentText = editor.attributedText ?? NSAttributedString(string: editor.text ?? "")
            let currentValue: Int
            if selection.length > 0, selection.location != NSNotFound,
               selection.location < currentText.length {
                currentValue = (currentText.attribute(key, at: selection.location, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
            } else {
                currentValue = (editor.typingAttributes[key] as? NSNumber)?.intValue ?? 0
            }
            let value = currentValue == 0 ? NSUnderlineStyle.single.rawValue : 0
            mutateActiveInlineText { text, range in
                text.addAttribute(key, value: value, range: range)
            } typingMutation: { attributes in
                attributes[key] = value
            }
        }

        func changeActiveTextFontSize(by delta: CGFloat) {
            mutateActiveInlineText { text, range in
                text.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let currentFont = value as? UIFont ?? UIFont.systemFont(ofSize: 16)
                    let size = min(96, max(8, currentFont.pointSize + delta))
                    text.addAttribute(.font, value: currentFont.withSize(size), range: subrange)
                }
            } typingMutation: { attributes in
                let currentFont = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 16)
                attributes[.font] = currentFont.withSize(min(96, max(8, currentFont.pointSize + delta)))
            }
        }

        func changeActiveTextColor(_ color: UIColor) {
            mutateActiveInlineText { text, range in
                text.addAttribute(.foregroundColor, value: color, range: range)
            } typingMutation: { attributes in
                attributes[.foregroundColor] = color
            }
        }

        func applyActiveTextStyleToEditor() {
            guard let annotation = selectedTextAnnotation,
                  let editor = activeTextEditor else { return }
            let selection = editor.selectedRange
            activeTextEditorDisplayScale = max(currentPDFScaleFactor, 0.01)
            let annotationText = annotation.attributedText
            let displayText = displayText(from: annotationText, scale: activeTextEditorDisplayScale)
            editor.attributedText = displayText
            editor.selectedRange = NSRange(
                location: min(selection.location, displayText.length),
                length: min(selection.length, max(0, displayText.length - min(selection.location, displayText.length)))
            )
            editor.textAlignment = annotation.alignment
            editor.backgroundColor = annotation.fillColor
            editor.layer.borderWidth = annotation.borderColor.cgColor.alpha > 0 ? 1 : 0
            editor.layer.borderColor = annotation.borderColor.cgColor
            editor.tintColor = annotation.textColor
            editor.typingAttributes = displayAttributes(from: annotation.textAttributes, scale: activeTextEditorDisplayScale)
            updateActiveTextEditorMetrics(editor, scale: activeTextEditorDisplayScale)
        }

        /// PDF 페이지 단위로 저장된 폰트를 현재 화면 배율의 UIKit 폰트로 변환합니다.
        func displayText(from text: NSAttributedString, scale: CGFloat) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: text)
            let safeScale = max(scale, 0.01)
            result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                guard let font = value as? UIFont else { return }
                result.addAttribute(.font, value: font.withSize(font.pointSize * safeScale), range: range)
            }
            return result
        }

        /// 화면 배율이 적용된 편집기 폰트를 PDF 페이지 원본 단위로 되돌립니다.
        func annotationText(from text: NSAttributedString) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: text)
            let safeScale = max(activeTextEditorDisplayScale, 0.01)
            result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                guard let font = value as? UIFont else { return }
                result.addAttribute(.font, value: font.withSize(font.pointSize / safeScale), range: range)
            }
            return result
        }

        func displayAttributes(
            from attributes: [NSAttributedString.Key: Any],
            scale: CGFloat
        ) -> [NSAttributedString.Key: Any] {
            var result = attributes
            if let font = result[.font] as? UIFont {
                result[.font] = font.withSize(font.pointSize * max(scale, 0.01))
            }
            return result
        }

        /// 확대 중 현재 편집 문자열과 새로 입력될 문자의 크기를 같은 비율로 즉시 갱신합니다.
        func rescaleActiveTextEditor(to requestedScale: CGFloat) {
            guard let editor = activeTextEditor else { return }
            let nextScale = max(requestedScale, 0.01)
            let previousScale = max(activeTextEditorDisplayScale, 0.01)
            let ratio = nextScale / previousScale
            guard ratio.isFinite, abs(ratio - 1) > 0.001 else {
                updateActiveTextEditorMetrics(editor, scale: nextScale)
                activeTextEditorDisplayScale = nextScale
                return
            }

            let selection = editor.selectedRange
            let text = NSMutableAttributedString(attributedString: editor.attributedText ?? NSAttributedString(string: editor.text ?? ""))
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let font = value as? UIFont else { return }
                text.addAttribute(.font, value: font.withSize(font.pointSize * ratio), range: range)
            }
            editor.attributedText = text
            editor.selectedRange = selection
            if let typingFont = editor.typingAttributes[.font] as? UIFont {
                editor.typingAttributes[.font] = typingFont.withSize(typingFont.pointSize * ratio)
            }
            activeTextEditorDisplayScale = nextScale
            updateActiveTextEditorMetrics(editor, scale: nextScale)
        }

        func updateActiveTextEditorMetrics(_ editor: PortalPDFTextEditorView, scale: CGFloat) {
            let safeScale = max(scale, 0.01)
            editor.textContainerInset = UIEdgeInsets(
                top: 8 * safeScale,
                left: 8 * safeScale,
                bottom: 8 * safeScale,
                right: 8 * safeScale
            )
            editor.layer.cornerRadius = 6 * safeScale
        }

        func presentTextFontPicker() {
            guard let pdfView,
                  let editor = activeTextEditor else { return }
            let configuration = UIFontPickerViewController.Configuration()
            configuration.includeFaces = true
            let picker = UIFontPickerViewController(configuration: configuration)
            picker.delegate = self
            isPresentingTextFontPicker = true
            textFontPickerSelection = editor.selectedRange
            var presenter = pdfView.window?.rootViewController
            while let presented = presenter?.presentedViewController {
                presenter = presented
            }
            guard let presenter else {
                isPresentingTextFontPicker = false
                textFontPickerSelection = nil
                return
            }
            presenter.present(picker, animated: true)
        }

        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            if let descriptor = viewController.selectedFontDescriptor {
                updateActiveTextStyle { annotation in
                    annotation.fontName = descriptor.postscriptName
                }
            }
            viewController.dismiss(animated: true) { [weak self] in
                self?.restoreTextEditorAfterFontPicker()
            }
        }

        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
            viewController.dismiss(animated: true) { [weak self] in
                self?.restoreTextEditorAfterFontPicker()
            }
        }

        /// 폰트 선택 전 PDF 주석 위치와 커서를 그대로 복원하고 편집을 이어갑니다.
        func restoreTextEditorAfterFontPicker() {
            defer {
                isPresentingTextFontPicker = false
                textFontPickerSelection = nil
            }
            guard let pdfView,
                  let editor = activeTextEditor,
                  let annotation = selectedTextAnnotation,
                  let page = annotation.page,
                  let editorContainer = editor.superview else { return }
            pdfView.layoutIfNeeded()
            let frameInPDFView = pdfView.convert(annotation.editingBounds, from: page).standardized
            editor.frame = editorContainer.convert(frameInPDFView, from: pdfView).standardized
            if let selection = textFontPickerSelection {
                let textLength = editor.attributedText?.length ?? (editor.text as NSString?)?.length ?? 0
                let location = min(selection.location, textLength)
                editor.selectedRange = NSRange(
                    location: location,
                    length: min(selection.length, max(0, textLength - location))
                )
            }
            pdfView.bringSubviewToFront(editorContainer)
            editor.becomeFirstResponder()
            restoreNativeTextEditorGestures(editor)
            keepActiveTextEditorVisible()
        }

        func toggleActiveTextLink() {
            guard let annotation = selectedTextAnnotation,
                  let editor = activeTextEditor else { return }
            if annotation.linkURL != nil {
                annotation.linkURL = nil
                annotation.isUnderlined = false
                applyActiveTextStyleToEditor()
                documentChangedHandler()
                return
            }
            let range = editor.selectedRange
            let textLength = (editor.text as NSString).length
            let selectedText = range.location != NSNotFound && NSMaxRange(range) <= textLength
                ? (editor.text as NSString).substring(with: range)
                : ""
            let candidate = (selectedText.isEmpty ? editor.text : selectedText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            annotation.linkURL = url.absoluteString
            annotation.isUnderlined = true
            annotation.textColor = .systemBlue
            applyActiveTextStyleToEditor()
            documentChangedHandler()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard textView === activeTextEditor,
                  let editor = activeTextEditor,
                  let annotation = selectedTextAnnotation,
                  let pdfView,
                  let page = annotation.page else { return }
            annotation.setAttributedText(annotationText(from: editor.attributedText ?? NSAttributedString(string: editor.text ?? "")))
            let fittingHeight = editor.sizeThatFits(
                CGSize(width: editor.bounds.width, height: CGFloat.greatestFiniteMagnitude)
            ).height
            var frame = editor.frame
            let minimumHeight: CGFloat = 44
            let maximumHeight = max(80, pdfView.bounds.height * 0.7)
            frame.size.height = min(max(minimumHeight, fittingHeight), maximumHeight)
            let pageBounds = page.bounds(for: .cropBox)
            let frameInPDFView = editor.superview?.convert(frame, to: pdfView) ?? frame
            annotation.editingBounds = pdfView.convert(frameInPDFView, to: page).standardized.clampedInside(pageBounds)
            let normalizedFrameInPDFView = pdfView.convert(annotation.editingBounds, from: page).standardized
            editor.frame = editor.superview?.convert(normalizedFrameInPDFView, from: pdfView).standardized
                ?? normalizedFrameInPDFView
            annotation.prepareForPersistence()
            documentChangedHandler()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard textView === activeTextEditor,
                  !isFinishingTextEditing,
                  !isPresentingTextFontPicker else { return }
            finishTextEditing()
        }

        /// 현재 텍스트 입력을 확정하고 PDF 링크 Annotation과 편집 히스토리를 갱신합니다.
        func finishTextEditing() {
            guard !isFinishingTextEditing,
                  let editor = activeTextEditor,
                  let annotation = selectedTextAnnotation else { return }
            isFinishingTextEditing = true
            let annotationPage = annotation.page
            annotation.setAttributedText(annotationText(from: editor.attributedText ?? NSAttributedString(string: editor.text ?? "")))
            annotation.prepareForPersistence()
            annotation.isPortalTextEditing = false
            annotation.isPortalTextSelected = false
            editor.delegate = nil
            if editor.isFirstResponder {
                editor.resignFirstResponder()
            }
            let editorContainer = editor.superview
            editor.removeFromSuperview()
            if editorContainer === textEditingHostView {
                editorContainer?.removeFromSuperview()
                textEditingHostView = nil
            } else {
                editorContainer?.isUserInteractionEnabled = false
            }
            activeTextEditor = nil
            selectedTextAnnotation = nil
            activeTextEditorDisplayScale = 1
            (pdfView as? PortalPDFView)?.protectedTextInputView = nil
            restorePDFBackgroundInteractions()
            textTapGesture?.isEnabled = selectedTool == .text
            textTouchDownGesture?.isEnabled = selectedTool == .text
            textDeleteTapGesture?.isEnabled = selectedTool == .text
            textLongPressGesture?.isEnabled = selectedTool == .text
            if let textKeyboardObserver {
                NotificationCenter.default.removeObserver(textKeyboardObserver)
                self.textKeyboardObserver = nil
            }
            if let pdfView {
                syncTextLink(for: annotation)
                if let annotationPage {
                    // 커스텀 draw 플래그를 원복한 뒤 페이지 Annotation을 같은 순서로 다시 등록합니다.
                    // 단순 setNeedsDisplay로 남을 수 있는 PDFKit 타일 캐시를 제거해 확정 문구를 즉시 표시합니다.
                    refreshPortalAnnotationTiles([(annotationPage, annotation)], in: pdfView)
                } else {
                    refreshPDFViewAfterAnnotationMutation(in: pdfView)
                }
            }
            isFinishingTextEditing = false
            onDocumentChanged()
        }

        func syncTextLink(for annotation: PortalPDFTextAnnotation) {
            guard let page = annotation.page else { return }
            page.annotations.filter { $0.userName == annotation.linkAnnotationUserName }.forEach {
                page.removeAnnotation($0)
            }
            guard let linkURL = annotation.linkURL,
                  let url = URL(string: linkURL) else { return }
            let link = PDFAnnotation(bounds: annotation.editingBounds, forType: .link, withProperties: nil)
            link.url = url
            link.userName = annotation.linkAnnotationUserName
            link.shouldDisplay = true
            link.shouldPrint = true
            page.addAnnotation(link)
        }

        /// 올가미로 선택된 주석을 제거하고 삭제 전 화면 타일까지 확실히 무효화합니다.
        func deleteLassoSelection(in pdfView: PDFView) {
            let targets = selectedLassoAnnotations.compactMap { annotation -> (PDFPage, PDFAnnotation)? in
                guard let page = annotation.page else { return nil }
                return (page, annotation)
            }
            guard !targets.isEmpty else {
                clearLassoSelection()
                return
            }

            // 삭제 뒤에는 annotation.page가 nil이 되므로 삭제 전에 화면 갱신 영역을 계산합니다.
            let dirtyViewRects = targets.map { page, annotation in
                let padding = max(12 / currentPDFScaleFactor, annotation.border?.lineWidth ?? 1)
                return pdfView.convert(
                    lassoSelectionBounds(for: annotation).insetBy(dx: -padding, dy: -padding),
                    from: page
                )
            }
            targets.forEach { page, annotation in
                annotation.shouldDisplay = false
                annotation.shouldPrint = false
                page.removeAnnotation(annotation)
            }
            clearLassoSelection()

            // 삭제된 객체가 들어 있던 페이지의 남은 주석을 재등록해 PDFKit 타일 캐시에서
            // 삭제 전 픽셀이 다시 사용되지 않게 합니다. PDFDocument/PDFView는 유지합니다.
            refreshPortalAnnotationTiles(targets, in: pdfView)
            refreshPDFViewDuringEraser(in: pdfView, dirtyViewRects: dirtyViewRects)
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                self.refreshPDFViewDuringEraser(in: pdfView, dirtyViewRects: dirtyViewRects)
                self.refreshPDFViewAfterAnnotationMutation(in: pdfView)
            }
            onDocumentChanged()
        }

        /// 자유형 영역으로 편집 주석을 선택하고 선택된 항목을 한 번에 이동합니다.
        func handleLassoGesture(
            _ state: UIGestureRecognizer.State,
            page: PDFPage,
            point: CGPoint,
            in pdfView: PDFView
        ) {
            switch state {
            case .began:
                activeLassoDidMove = false
                let viewPoint = pdfView.convert(point, from: page)
                if activeLassoPage === page,
                   isLassoTransformHandleHit(viewPoint, in: pdfView),
                   let selectedLassoBounds,
                   !selectedLassoAnnotations.isEmpty {
                    let center = CGPoint(x: selectedLassoBounds.midX, y: selectedLassoBounds.midY)
                    activeLassoTransformState = (
                        distance: max(hypot(point.x - center.x, point.y - center.y), 1),
                        angle: atan2(point.y - center.y, point.x - center.x)
                    )
                    isMovingLassoSelection = false
                    return
                }
                if activeLassoPage === page,
                   isPointInsideLassoSelection(point, padding: 8 / currentPDFScaleFactor),
                   !selectedLassoAnnotations.isEmpty {
                    isMovingLassoSelection = true
                    activeLassoMovePoint = point
                    return
                }
                clearLassoSelection()
                clearSelectedImageAnnotation()
                clearSelectedShapeAnnotation()
                activeLassoPage = page
                activeLassoPoints = [point]
                isMovingLassoSelection = false
                updateLassoDrawingOverlay(in: pdfView)
            case .changed:
                guard activeLassoPage === page else { return }
                if let transformState = activeLassoTransformState,
                   let selectedLassoBounds {
                    let center = CGPoint(x: selectedLassoBounds.midX, y: selectedLassoBounds.midY)
                    let distance = max(hypot(point.x - center.x, point.y - center.y), 1)
                    let angle = atan2(point.y - center.y, point.x - center.x)
                    transformLassoSelection(
                        scale: distance / max(transformState.distance, 1),
                        rotation: normalizedAngle(angle - transformState.angle),
                        on: page
                    )
                    activeLassoTransformState = (distance: distance, angle: angle)
                    activeLassoDidMove = true
                    updateLassoSelectionOverlay(in: pdfView)
                } else if isMovingLassoSelection {
                    guard let previousPoint = activeLassoMovePoint else {
                        activeLassoMovePoint = point
                        return
                    }
                    let proposedDelta = CGPoint(x: point.x - previousPoint.x, y: point.y - previousPoint.y)
                    let appliedDelta = moveLassoSelection(by: proposedDelta, on: page)
                    activeLassoMovePoint = CGPoint(
                        x: previousPoint.x + appliedDelta.x,
                        y: previousPoint.y + appliedDelta.y
                    )
                    activeLassoDidMove = activeLassoDidMove || appliedDelta != .zero
                    updateLassoSelectionOverlay(in: pdfView)
                } else {
                    if let previousPoint = activeLassoPoints.last,
                       hypot(point.x - previousPoint.x, point.y - previousPoint.y) < 1 / currentPDFScaleFactor {
                        return
                    }
                    activeLassoPoints.append(point)
                    updateLassoDrawingOverlay(in: pdfView)
                }
            case .ended:
                if activeLassoTransformState != nil {
                    if activeLassoDidMove {
                        onDocumentChanged()
                    }
                } else if isMovingLassoSelection {
                    if activeLassoDidMove {
                        onDocumentChanged()
                    }
                } else if activeLassoPage === page {
                    activeLassoPoints.append(point)
                    completeLassoSelection(on: page, in: pdfView)
                }
                activeLassoMovePoint = nil
                activeLassoTransformState = nil
                isMovingLassoSelection = false
                activeLassoDidMove = false
            case .cancelled, .failed:
                activeLassoMovePoint = nil
                activeLassoTransformState = nil
                isMovingLassoSelection = false
                activeLassoDidMove = false
                if selectedLassoAnnotations.isEmpty {
                    clearLassoSelection()
                } else {
                    updateLassoSelectionOverlay(in: pdfView)
                }
            default:
                break
            }
        }

        /// 닫힌 올가미 경로 안에 포함된 편집 가능한 주석을 선택합니다.
        func completeLassoSelection(on page: PDFPage, in pdfView: PDFView) {
            guard activeLassoPoints.count >= 3 else {
                clearLassoSelection()
                return
            }
            let path = UIBezierPath()
            path.move(to: activeLassoPoints[0])
            activeLassoPoints.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            let lassoBounds = path.bounds
            selectedLassoAnnotations = page.annotations.filter { annotation in
                let annotationBounds = lassoSelectionBounds(for: annotation)
                guard isHistoryEditableAnnotation(annotation),
                      annotation.shouldDisplay || PortalPDFInkDisplaySuppression.isSuppressed(annotation),
                      lassoBounds.intersects(annotationBounds) else { return false }
                let bounds = annotationBounds
                let samples = [
                    CGPoint(x: bounds.midX, y: bounds.midY),
                    CGPoint(x: bounds.minX, y: bounds.minY),
                    CGPoint(x: bounds.maxX, y: bounds.minY),
                    CGPoint(x: bounds.minX, y: bounds.maxY),
                    CGPoint(x: bounds.maxX, y: bounds.maxY)
                ]
                return samples.contains(where: path.contains)
            }
            // 선택 점선은 선택된 객체 전체의 bounds가 아니라 사용자가 실제로 감싼
            // 올가미 영역만 표시합니다. 이동·변형 시에도 이 외곽선을 함께 변환합니다.
            selectedLassoOutlinePoints = activeLassoPoints
            selectedLassoBounds = lassoBounds
            selectedLassoRotation = 0
            activeLassoPoints = []
            if selectedLassoAnnotations.isEmpty {
                clearLassoSelection()
            } else {
                updateLassoSelectionOverlay(in: pdfView)
            }
        }

        func lassoSelectionBounds(for annotation: PDFAnnotation) -> CGRect {
            (annotation as? PortalPDFImageAnnotation)?.editingBounds ?? annotation.bounds
        }

        /// 선택된 주석 전체가 페이지 밖으로 나가지 않는 범위에서 동일한 이동량을 적용합니다.
        @discardableResult
        func moveLassoSelection(by proposedDelta: CGPoint, on page: PDFPage) -> CGPoint {
            guard let selectedLassoBounds, !selectedLassoAnnotations.isEmpty else { return .zero }
            let pageBounds = page.bounds(for: .cropBox)
            let rotatedBounds = lassoRotatedPageBounds() ?? selectedLassoBounds
            let minimumX = pageBounds.minX - rotatedBounds.minX
            let maximumX = pageBounds.maxX - rotatedBounds.maxX
            let minimumY = pageBounds.minY - rotatedBounds.minY
            let maximumY = pageBounds.maxY - rotatedBounds.maxY
            let delta = CGPoint(
                x: min(max(proposedDelta.x, minimumX), maximumX),
                y: min(max(proposedDelta.y, minimumY), maximumY)
            )
            guard delta != .zero else { return .zero }

            selectedLassoAnnotations.forEach { annotation in
                if let pressureAnnotation = annotation as? PortalPDFPressureInkAnnotation {
                    pressureAnnotation.translateStroke(by: delta)
                } else if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                    imageAnnotation.editingBounds = imageAnnotation.editingBounds.offsetBy(dx: delta.x, dy: delta.y)
                } else if let shapeAnnotation = annotation as? PortalPDFShapeAnnotation {
                    shapeAnnotation.editingBounds = shapeAnnotation.editingBounds.offsetBy(dx: delta.x, dy: delta.y)
                } else {
                    annotation.bounds = annotation.bounds.offsetBy(dx: delta.x, dy: delta.y)
                }
            }
            selectedLassoOutlinePoints = selectedLassoOutlinePoints.map {
                CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            }
            self.selectedLassoBounds = selectedLassoBounds.offsetBy(dx: delta.x, dy: delta.y)
            pdfView?.setNeedsDisplay()
            return delta
        }

        /// 선택된 주석 전체를 선택 영역 중심 기준으로 확대·축소하고 회전합니다.
        func transformLassoSelection(scale proposedScale: CGFloat, rotation: CGFloat, on page: PDFPage) {
            guard let selectedLassoBounds, !selectedLassoAnnotations.isEmpty else { return }
            let pageBounds = page.bounds(for: .cropBox)
            let minimumScale = max(
                0.2,
                max(24 / max(selectedLassoBounds.width, 1), 24 / max(selectedLassoBounds.height, 1))
            )
            let maximumScale = min(
                5,
                min(
                    pageBounds.width / max(selectedLassoBounds.width, 1),
                    pageBounds.height / max(selectedLassoBounds.height, 1)
                )
            )
            let scale = min(max(proposedScale, minimumScale), maximumScale)
            let center = CGPoint(x: selectedLassoBounds.midX, y: selectedLassoBounds.midY)
            let cosine = cos(rotation)
            let sine = sin(rotation)

            func transformedPoint(_ point: CGPoint) -> CGPoint {
                let offsetX = (point.x - center.x) * scale
                let offsetY = (point.y - center.y) * scale
                return CGPoint(
                    x: center.x + offsetX * cosine - offsetY * sine,
                    y: center.y + offsetX * sine + offsetY * cosine
                )
            }

            func transformedRect(_ rect: CGRect) -> CGRect {
                let transformedCenter = transformedPoint(CGPoint(x: rect.midX, y: rect.midY))
                return CGRect(
                    x: transformedCenter.x - rect.width * scale / 2,
                    y: transformedCenter.y - rect.height * scale / 2,
                    width: rect.width * scale,
                    height: rect.height * scale
                )
            }

            selectedLassoAnnotations.forEach { annotation in
                if let pressureAnnotation = annotation as? PortalPDFPressureInkAnnotation {
                    pressureAnnotation.transformStroke(scale: scale, rotation: rotation, around: center)
                } else if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                    imageAnnotation.editingBounds = transformedRect(imageAnnotation.editingBounds)
                    imageAnnotation.rotationAngle += rotation
                } else if let shapeAnnotation = annotation as? PortalPDFShapeAnnotation {
                    shapeAnnotation.editingBounds = transformedRect(shapeAnnotation.editingBounds)
                    shapeAnnotation.rotationAngle += rotation
                } else if let paths = annotation.paths, !paths.isEmpty {
                    var transform = CGAffineTransform.identity
                    transform = transform.translatedBy(x: center.x, y: center.y)
                    transform = transform.rotated(by: rotation)
                    transform = transform.scaledBy(x: scale, y: scale)
                    transform = transform.translatedBy(x: -center.x, y: -center.y)
                    let transformedPaths = paths.compactMap { path -> UIBezierPath? in
                        var pathTransform = transform
                        guard let transformedPath = path.cgPath.copy(using: &pathTransform) else { return nil }
                        return UIBezierPath(cgPath: transformedPath)
                    }
                    paths.forEach { annotation.remove($0) }
                    transformedPaths.forEach { annotation.add($0) }
                    if let pathBounds = transformedPaths.map(\.bounds).unionRect {
                        let padding = max(annotation.border?.lineWidth ?? 1, 2)
                        annotation.bounds = pathBounds.insetBy(dx: -padding, dy: -padding)
                    }
                } else {
                    annotation.bounds = transformedRect(annotation.bounds)
                }
            }
            selectedLassoOutlinePoints = selectedLassoOutlinePoints.map(transformedPoint)

            self.selectedLassoBounds = CGRect(
                x: center.x - selectedLassoBounds.width * scale / 2,
                y: center.y - selectedLassoBounds.height * scale / 2,
                width: selectedLassoBounds.width * scale,
                height: selectedLassoBounds.height * scale
            )
            selectedLassoRotation = normalizedAngle(selectedLassoRotation + rotation)
            guard let transformedBounds = lassoRotatedPageBounds() else { return }
            let correction = CGPoint(
                x: transformedBounds.minX < pageBounds.minX
                    ? pageBounds.minX - transformedBounds.minX
                    : (transformedBounds.maxX > pageBounds.maxX ? pageBounds.maxX - transformedBounds.maxX : 0),
                y: transformedBounds.minY < pageBounds.minY
                    ? pageBounds.minY - transformedBounds.minY
                    : (transformedBounds.maxY > pageBounds.maxY ? pageBounds.maxY - transformedBounds.maxY : 0)
            )
            if correction != .zero {
                _ = moveLassoSelection(by: correction, on: page)
            }
            pdfView?.setNeedsDisplay()
        }

        /// 자유형 선택 경로를 PDFView 화면 좌표로 표시합니다.
        func updateLassoDrawingOverlay(in pdfView: PDFView) {
            guard let page = activeLassoPage, let firstPoint = activeLassoPoints.first else { return }
            let path = UIBezierPath()
            path.move(to: pdfView.convert(firstPoint, from: page))
            activeLassoPoints.dropFirst().forEach {
                path.addLine(to: pdfView.convert($0, from: page))
            }
            path.close()
            let layer = lassoOverlay(in: pdfView)
            layer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
            layer.path = path.cgPath
        }

        /// 선택 결과를 점선 사각형으로 표시합니다.
        func updateLassoSelectionOverlay(in pdfView: PDFView) {
            guard let page = activeLassoPage else { return }
            let pageCorners = lassoPageCorners()
            guard pageCorners.count == 4,
                  let firstOutlinePoint = selectedLassoOutlinePoints.first else { return }
            let viewCorners = pageCorners.map { pdfView.convert($0, from: page) }
            let layer = lassoOverlay(in: pdfView)
            layer.fillColor = UIColor.clear.cgColor
            let path = UIBezierPath()
            path.move(to: pdfView.convert(firstOutlinePoint, from: page))
            selectedLassoOutlinePoints.dropFirst().forEach {
                path.addLine(to: pdfView.convert($0, from: page))
            }
            path.close()
            layer.path = path.cgPath
            updateLassoHandleLayers(
                deleteCenter: viewCorners[0],
                transformCenter: viewCorners[1],
                in: pdfView
            )
        }

        /// 선택 영역 왼쪽 상단에는 삭제, 오른쪽 상단에는 확대·축소·회전 조작점을 표시합니다.
        func updateLassoHandleLayers(
            deleteCenter: CGPoint,
            transformCenter: CGPoint,
            in pdfView: PDFView
        ) {
            let radius: CGFloat = 14

            let deleteLayer = lassoDeleteHandleLayer ?? CAShapeLayer()
            deleteLayer.frame = pdfView.bounds
            deleteLayer.path = UIBezierPath(ovalIn: CGRect(
                x: deleteCenter.x - radius,
                y: deleteCenter.y - radius,
                width: radius * 2,
                height: radius * 2
            )).cgPath
            deleteLayer.fillColor = UIColor.systemRed.cgColor
            deleteLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
            deleteLayer.lineWidth = 1
            deleteLayer.zPosition = 10_001
            if deleteLayer.superlayer == nil { pdfView.layer.addSublayer(deleteLayer) }
            lassoDeleteHandleLayer = deleteLayer

            let deleteIcon = lassoDeleteIconLayer ?? CAShapeLayer()
            deleteIcon.frame = pdfView.bounds
            let deletePath = UIBezierPath()
            deletePath.move(to: CGPoint(x: deleteCenter.x - 4, y: deleteCenter.y - 4))
            deletePath.addLine(to: CGPoint(x: deleteCenter.x + 4, y: deleteCenter.y + 4))
            deletePath.move(to: CGPoint(x: deleteCenter.x + 4, y: deleteCenter.y - 4))
            deletePath.addLine(to: CGPoint(x: deleteCenter.x - 4, y: deleteCenter.y + 4))
            deleteIcon.path = deletePath.cgPath
            deleteIcon.strokeColor = UIColor.white.cgColor
            deleteIcon.fillColor = UIColor.clear.cgColor
            deleteIcon.lineWidth = 2
            deleteIcon.lineCap = .round
            deleteIcon.zPosition = 10_002
            if deleteIcon.superlayer == nil { pdfView.layer.addSublayer(deleteIcon) }
            lassoDeleteIconLayer = deleteIcon

            let transformLayer = lassoTransformHandleLayer ?? CAShapeLayer()
            transformLayer.frame = pdfView.bounds
            transformLayer.path = UIBezierPath(ovalIn: CGRect(
                x: transformCenter.x - radius,
                y: transformCenter.y - radius,
                width: radius * 2,
                height: radius * 2
            )).cgPath
            transformLayer.fillColor = UIColor.systemBackground.cgColor
            transformLayer.strokeColor = UIColor.systemBlue.cgColor
            transformLayer.lineWidth = 1.5
            transformLayer.zPosition = 10_001
            if transformLayer.superlayer == nil { pdfView.layer.addSublayer(transformLayer) }
            lassoTransformHandleLayer = transformLayer

            let transformIcon = lassoTransformIconLayer ?? CAShapeLayer()
            transformIcon.frame = pdfView.bounds
            let transformPath = UIBezierPath()
            transformPath.move(to: CGPoint(x: transformCenter.x - 5, y: transformCenter.y + 5))
            transformPath.addLine(to: CGPoint(x: transformCenter.x + 5, y: transformCenter.y - 5))
            transformPath.move(to: CGPoint(x: transformCenter.x + 1, y: transformCenter.y - 5))
            transformPath.addLine(to: CGPoint(x: transformCenter.x + 5, y: transformCenter.y - 5))
            transformPath.addLine(to: CGPoint(x: transformCenter.x + 5, y: transformCenter.y - 1))
            transformPath.move(to: CGPoint(x: transformCenter.x - 1, y: transformCenter.y + 5))
            transformPath.addLine(to: CGPoint(x: transformCenter.x - 5, y: transformCenter.y + 5))
            transformPath.addLine(to: CGPoint(x: transformCenter.x - 5, y: transformCenter.y + 1))
            transformIcon.path = transformPath.cgPath
            transformIcon.strokeColor = UIColor.systemBlue.cgColor
            transformIcon.fillColor = UIColor.clear.cgColor
            transformIcon.lineWidth = 1.8
            transformIcon.lineCap = .round
            transformIcon.lineJoin = .round
            transformIcon.zPosition = 10_002
            if transformIcon.superlayer == nil { pdfView.layer.addSublayer(transformIcon) }
            lassoTransformIconLayer = transformIcon
        }

        func isLassoTransformHandleHit(_ viewPoint: CGPoint, in pdfView: PDFView) -> Bool {
            guard let page = activeLassoPage else { return false }
            let corners = lassoPageCorners()
            guard corners.count == 4 else { return false }
            let center = pdfView.convert(corners[1], from: page)
            return hypot(viewPoint.x - center.x, viewPoint.y - center.y) <= 22
        }

        func isLassoDeleteHandleHit(_ viewPoint: CGPoint, in pdfView: PDFView) -> Bool {
            guard let page = activeLassoPage else { return false }
            let corners = lassoPageCorners()
            guard corners.count == 4 else { return false }
            let center = pdfView.convert(corners[0], from: page)
            return hypot(viewPoint.x - center.x, viewPoint.y - center.y) <= 22
        }

        /// 선택 프레임의 왼쪽 상단부터 시계 방향으로 회전된 Page 좌표를 반환합니다.
        func lassoPageCorners(padding: CGFloat = 0) -> [CGPoint] {
            guard let selectedLassoBounds else { return [] }
            let bounds = selectedLassoBounds.insetBy(dx: -padding, dy: -padding)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let cosine = cos(selectedLassoRotation)
            let sine = sin(selectedLassoRotation)
            func rotate(_ point: CGPoint) -> CGPoint {
                let offsetX = point.x - center.x
                let offsetY = point.y - center.y
                return CGPoint(
                    x: center.x + offsetX * cosine - offsetY * sine,
                    y: center.y + offsetX * sine + offsetY * cosine
                )
            }
            return [
                rotate(CGPoint(x: bounds.minX, y: bounds.maxY)),
                rotate(CGPoint(x: bounds.maxX, y: bounds.maxY)),
                rotate(CGPoint(x: bounds.maxX, y: bounds.minY)),
                rotate(CGPoint(x: bounds.minX, y: bounds.minY))
            ]
        }

        /// 회전된 선택 프레임 안에 Page 좌표가 포함되는지 확인합니다.
        func isPointInsideLassoSelection(_ point: CGPoint, padding: CGFloat) -> Bool {
            guard let firstPoint = selectedLassoOutlinePoints.first else { return false }
            let path = UIBezierPath()
            path.move(to: firstPoint)
            selectedLassoOutlinePoints.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            guard padding > 0 else { return path.contains(point) }
            let paddedPath = path.cgPath.copy(
                strokingWithWidth: padding * 2,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 0
            )
            return path.contains(point) || paddedPath.contains(point)
        }

        /// 회전된 선택 프레임의 Page 좌표 기준 외곽 영역을 계산합니다.
        func lassoRotatedPageBounds() -> CGRect? {
            let corners = lassoPageCorners()
            guard let first = corners.first else { return nil }
            return corners.dropFirst().reduce(
                CGRect(origin: first, size: .zero)
            ) { partialResult, point in
                partialResult.union(CGRect(origin: point, size: .zero))
            }
        }

        /// 올가미 선택 화면 Layer를 생성하거나 기존 Layer를 반환합니다.
        func lassoOverlay(in pdfView: PDFView) -> CAShapeLayer {
            if let lassoOverlayLayer {
                lassoOverlayLayer.frame = pdfView.bounds
                return lassoOverlayLayer
            }
            let layer = CAShapeLayer()
            layer.frame = pdfView.bounds
            layer.strokeColor = UIColor.systemBlue.cgColor
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 1.5
            layer.lineDashPattern = [6, 4]
            layer.zPosition = 10_000
            pdfView.layer.addSublayer(layer)
            lassoOverlayLayer = layer
            return layer
        }

        /// 올가미 선택 상태와 화면 표시를 모두 제거합니다.
        func clearLassoSelection() {
            lassoOverlayLayer?.removeFromSuperlayer()
            lassoOverlayLayer = nil
            lassoDeleteHandleLayer?.removeFromSuperlayer()
            lassoDeleteHandleLayer = nil
            lassoDeleteIconLayer?.removeFromSuperlayer()
            lassoDeleteIconLayer = nil
            lassoTransformHandleLayer?.removeFromSuperlayer()
            lassoTransformHandleLayer = nil
            lassoTransformIconLayer?.removeFromSuperlayer()
            lassoTransformIconLayer = nil
            activeLassoPage = nil
            activeLassoPoints = []
            selectedLassoAnnotations = []
            selectedLassoBounds = nil
            selectedLassoOutlinePoints = []
            selectedLassoRotation = 0
            activeLassoMovePoint = nil
            isMovingLassoSelection = false
            activeLassoDidMove = false
            activeLassoTransformState = nil
        }

        /// 지우개 전용 Gesture의 coalesced 좌표를 삭제 큐에 전달하고 커서는 최신 터치로 즉시 이동합니다.
        @objc private func handleEraserDrawing(_ recognizer: PortalPDFEraserGestureRecognizer) {
            guard selectedTool == .eraser, let pdfView else { return }
            let viewPoints = recognizer.sampledLocations
            if let latestPoint = viewPoints.last {
                updateEraserOverlay(at: latestPoint)
            }

            switch recognizer.state {
            case .began:
                guard let firstPoint = viewPoints.first else { return }
                processEraserSample(firstPoint, state: .began, in: pdfView)
                viewPoints.dropFirst().forEach {
                    processEraserSample($0, state: .changed, in: pdfView)
                }
            case .changed:
                viewPoints.forEach {
                    processEraserSample($0, state: .changed, in: pdfView)
                }
            case .ended:
                guard let lastPoint = viewPoints.last else {
                    finishEraserGesture(in: pdfView)
                    return
                }
                viewPoints.dropLast().forEach {
                    processEraserSample($0, state: .changed, in: pdfView)
                }
                processEraserSample(lastPoint, state: .ended, in: pdfView)
            case .cancelled, .failed:
                finishEraserGesture(in: pdfView)
            default:
                break
            }
        }

        func processEraserSample(
            _ viewPoint: CGPoint,
            state: UIGestureRecognizer.State,
            in pdfView: PDFView
        ) {
            guard let page = pdfView.page(for: viewPoint, nearest: true) else {
                if state == .ended { finishEraserGesture(in: pdfView) }
                return
            }
            handleEraseGesture(
                state,
                page: page,
                point: pdfView.convert(viewPoint, to: page)
            )
        }

        /// 펜 전용 Gesture가 전달한 coalesced touch 지점을 하나의 연속 경로로 누적합니다.
        @objc private func handlePenDrawing(_ recognizer: PortalPDFPenGestureRecognizer) {
            guard selectedTool.isInkTool, let pdfView else { return }
            let viewPoints = recognizer.sampledLocations
            let viewPressures = recognizer.sampledPressures

            switch recognizer.state {
            case .began:
                guard let firstViewPoint = viewPoints.first,
                      let page = pdfView.page(for: firstViewPoint, nearest: false) else {
                    return
                }
                onBeginPenDrawing()
                if selectedTool == .neon {
                    neonClearWorkItem?.cancel()
                    neonClearWorkItem = nil
                }
                (pdfView as? PortalPDFView)?.cancelDocumentActions()
                let firstPagePoint = pdfView.convert(firstViewPoint, to: page)
                activePenPage = page
                activePenPath = makeRoundedPath(startPoint: firstPagePoint)
                activePenPagePoints = [firstPagePoint]
                activePenViewPoints = [firstViewPoint]
                activePenPressures = [adjustedPenPressure(viewPressures.first ?? 0.5)]
                activePenOverlayPath = makeRoundedPath(startPoint: firstViewPoint)
                activePenLastViewPoint = firstViewPoint
                activePenSampleCount = 1
                activePenPageCurvePoints[0] = firstPagePoint
                activePenViewCurvePoints[0] = firstViewPoint
                activePenCurveIndex = 0
                appendPenSamples(
                    viewPoints.dropFirst(),
                    pressures: viewPressures.dropFirst(),
                    to: page,
                    in: pdfView
                )
                flushActivePenOverlayRefresh()
            case .changed:
                guard let page = activePenPage else { return }
                appendPenSamples(viewPoints, pressures: viewPressures, to: page, in: pdfView)
                if penType == .pressure {
                    scheduleActivePenOverlayRefresh()
                }
            case .ended:
                guard let page = activePenPage,
                      let pagePath = activePenPath else {
                    resetActiveDrawing()
                    performPendingPencilDoubleTapIfNeeded()
                    return
                }
                appendPenSamples(viewPoints, pressures: viewPressures, to: page, in: pdfView)
                if penType != .pressure {
                    finishFileManagerRoundedPenPath()
                    applyLineCorrectionToFileManagerPathsIfNeeded()
                }
                let pointCountBeforeDot = activePenPagePoints.count
                ensureVisibleDotIfNeeded(pagePath: pagePath)
                var completedAnnotation: PDFAnnotation?
                if selectedTool == .neon {
                    flushActivePenOverlayRefresh()
                    addTransientNeonStroke(to: page)
                } else if penType == .pressure {
                    if activePenPagePoints.count == pointCountBeforeDot,
                       activePenPagePoints.count == 1 {
                        activePenPagePoints.append(pagePath.currentPoint)
                        activePenPressures.append(activePenPressures.last ?? 0.5)
                    }
                    flushActivePenOverlayRefresh()
                    completedAnnotation = addPressureInkAnnotations(to: page)
                } else {
                    flushActivePenOverlayRefresh()
                    completedAnnotation = addInkAnnotation(path: pagePath, to: page, isPathSmoothed: true)
                }
                if selectedTool == .neon {
                    resetActiveDrawing()
                    scheduleTransientNeonClear()
                } else {
                    // FileManager처럼 완료 비트맵이 준비될 때까지 실시간 레이어를 유지합니다.
                    // 준비 콜백에서 영구 이미지와 실시간 벡터를 한 트랜잭션으로 교체합니다.
                    let finishingLiveLayers: [CALayer] = [
                        activePenOverlayLayer,
                        activePressureOverlayLayer,
                    ].compactMap { $0 }
                    resetActiveDrawing(keepingInkOverlayLayers: true)
                    onDocumentChanged(
                        changedPages: [page],
                        appendedAnnotation: completedAnnotation,
                        appendedStrokeRasterReady: {
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            finishingLiveLayers.forEach { $0.removeFromSuperlayer() }
                            CATransaction.commit()
                        }
                    )
                }
                performPendingPencilDoubleTapIfNeeded()
            case .cancelled, .failed:
                resetActiveDrawing()
                if selectedTool == .neon, !transientNeonStrokes.isEmpty {
                    scheduleTransientNeonClear()
                }
                performPendingPencilDoubleTapIfNeeded()
            default:
                break
            }
        }

        /**
         제스처 인식 가능 여부를 현재 편집 도구 기준으로 제한합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - gestureRecognizer: 인식 여부를 판단할 Gesture Recognizer 입니다.
         - Returns: 현재 도구에서 사용 가능한 제스처인 경우 `true` 입니다.
         */
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === presentationSwipeUpGesture ||
                gestureRecognizer === presentationSwipeDownGesture {
                return true
            }
            // 텍스트 편집 중에도 PDF의 두 손가락 이동·확대는 유지합니다.
            if activeTextEditor != nil {
                if gestureRecognizer is UIPinchGestureRecognizer || gestureRecognizer === viewportPanGesture {
                    return true
                }
                return false
            }
            if gestureRecognizer === penDrawingGesture {
                return selectedTool.isInkTool
            }
            if gestureRecognizer === eraserDrawingGesture {
                return selectedTool == .eraser
            }
            if gestureRecognizer === lassoTapGesture {
                return selectedTool == .lasso && !selectedLassoAnnotations.isEmpty
            }
            if gestureRecognizer === drawingPanGesture, selectedTool == .lasso {
                // 삭제 조작점의 짧은 탭을 올가미 이동 Pan이 먼저 가져가면 삭제 Tap이
                // 실패합니다. 삭제 영역에서는 Pan을 시작하지 않아 Tap이 즉시 처리되게 합니다.
                if let pdfView,
                   !selectedLassoAnnotations.isEmpty,
                   isLassoDeleteHandleHit(gestureRecognizer.location(in: pdfView), in: pdfView) {
                    return false
                }
                return true
            }
            if gestureRecognizer === drawingPanGesture, selectedTool == .text {
                guard activeTextEditor == nil,
                      let pdfView,
                      let annotation = selectedTextAnnotation,
                      let page = annotation.page else { return false }
                let viewPoint = gestureRecognizer.location(in: pdfView)
                let pagePoint = pdfView.convert(viewPoint, to: page)
                if annotation.isDeleteHandleHit(pagePoint, scaleFactor: currentPDFScaleFactor) {
                    return false
                }
                if annotation.resizeHandle(at: pagePoint, scaleFactor: currentPDFScaleFactor) != nil {
                    return true
                }
                return annotation.editingBounds
                        .insetBy(dx: -18 / currentPDFScaleFactor, dy: -18 / currentPDFScaleFactor)
                        .contains(pagePoint)
            }
            if gestureRecognizer is UIPanGestureRecognizer {
                if selectedTool == .image {
                    if let selectedImageAnnotation,
                       selectedImageAnnotation.isPortalSelected,
                       let pdfView,
                       let page = pdfView.page(for: gestureRecognizer.location(in: pdfView), nearest: true),
                       selectedImageAnnotation.page === page {
                        let viewPoint = gestureRecognizer.location(in: pdfView)
                        let pagePoint = pdfView.convert(viewPoint, to: page)
                        if selectedImageAnnotation.isDeleteHandleHit(
                            pagePoint,
                            scaleFactor: currentPDFScaleFactor
                        ) {
                            return false
                        }
                        if selectedImageAnnotation.resizeHandle(
                            at: pagePoint,
                            scaleFactor: currentPDFScaleFactor
                        ) != nil {
                            return true
                        }
                        // 변형 핸들은 실제 이미지 본문 밖에 있으므로 본문 hit-test 전에
                        // Pan 시작을 허용해야 확대·축소·회전 제스처가 시작됩니다.
                        if selectedImageAnnotation.isTransformHandleHit(
                            pagePoint,
                            scaleFactor: currentPDFScaleFactor
                        ) {
                            return true
                        }
                    }
                    guard let pdfView,
                          let page = pdfView.page(for: gestureRecognizer.location(in: pdfView), nearest: true) else {
                        return false
                    }
                    let viewPoint = gestureRecognizer.location(in: pdfView)
                    let pagePoint = pdfView.convert(viewPoint, to: page)
                    return editableAnnotation(on: page, point: pagePoint) is PortalPDFImageAnnotation
                }
                if selectedTool == .box {
                    guard let pdfView,
                          let annotation = selectedShapeAnnotation,
                          annotation.isPortalSelected,
                          let page = pdfView.page(
                            for: gestureRecognizer.location(in: pdfView),
                            nearest: true
                          ),
                          annotation.page === page else { return false }
                    let viewPoint = gestureRecognizer.location(in: pdfView)
                    let pagePoint = pdfView.convert(viewPoint, to: page)
                    if annotation.isDeleteHandleHit(pagePoint, scaleFactor: currentPDFScaleFactor) {
                        return false
                    }
                    if annotation.resizeHandle(at: pagePoint, scaleFactor: currentPDFScaleFactor) != nil {
                        return true
                    }
                    return PortalPDFEditableAnnotationHitTesting.containsEditingContent(
                        annotation,
                        point: pagePoint,
                        padding: 18 / currentPDFScaleFactor
                    )
                }

                // 지우개는 이미지 위에서 시작할 때 이미지 편집 롱프레스에 우선권을 줍니다.
                // 펜은 이미지 위에서도 그대로 그릴 수 있어야 하므로 이 차단 조건을 적용하지 않습니다.
                if selectedTool == .eraser,
                   let pdfView,
                   let page = pdfView.page(for: gestureRecognizer.location(in: pdfView), nearest: true) {
                    let viewPoint = gestureRecognizer.location(in: pdfView)
                    let pagePoint = pdfView.convert(viewPoint, to: page)
                    if editableAnnotation(on: page, point: pagePoint) is PortalPDFImageAnnotation {
                        return false
                    }
                }

                return selectedTool.isInkTool
                    || selectedTool == .box
                    || selectedTool == .eraser
                    || selectedTool == .lasso
            }
            if gestureRecognizer === imageTapGesture {
                guard selectedTool == .image, let pdfView else { return false }
                return !isImageActionMenuHit(gestureRecognizer.location(in: pdfView), in: pdfView)
            }
            if gestureRecognizer === imageDeleteTapGesture {
                guard selectedTool == .image,
                      let selectedImageAnnotation,
                      selectedImageAnnotation.isPortalSelected,
                      let pdfView,
                      let page = pdfView.page(for: gestureRecognizer.location(in: pdfView), nearest: true),
                      selectedImageAnnotation.page === page else {
                    return false
                }
                let viewPoint = gestureRecognizer.location(in: pdfView)
                let pagePoint = pdfView.convert(viewPoint, to: page)
                return selectedImageAnnotation.isDeleteHandleHit(
                    pagePoint,
                    scaleFactor: currentPDFScaleFactor
                )
            }
            if gestureRecognizer === shapeTapGesture {
                return selectedTool == .box
            }
            if gestureRecognizer === textTapGesture {
                // 실제 UITextView 편집 중에는 모든 한 손가락 텍스트 제스처를
                // UIKit 입력기에 맡기되 입력기 밖 PDF 배경 탭은 편집 종료에 사용합니다.
                guard selectedTool == .text else { return false }
                guard let pdfView else { return false }
                if isTextActionMenuHit(gestureRecognizer.location(in: pdfView), in: pdfView) {
                    return false
                }
                guard let activeTextEditor else { return true }
                let point = gestureRecognizer.location(in: pdfView)
                let editorPoint = activeTextEditor.convert(point, from: pdfView)
                return !activeTextEditor.point(inside: editorPoint, with: nil)
            }
            if gestureRecognizer === textDeleteTapGesture {
                guard selectedTool == .text,
                      activeTextEditor == nil,
                      let pdfView,
                      let annotation = selectedTextAnnotation,
                      annotation.isPortalTextSelected,
                      let page = annotation.page else { return false }
                let viewPoint = gestureRecognizer.location(in: pdfView)
                let pagePoint = pdfView.convert(viewPoint, to: page)
                return annotation.isDeleteHandleHit(pagePoint, scaleFactor: currentPDFScaleFactor)
            }
            if gestureRecognizer === textLongPressGesture {
                guard selectedTool == .text,
                      activeTextEditor == nil,
                      let pdfView,
                      let annotation = selectedTextAnnotation,
                      let page = annotation.page else { return false }
                let viewPoint = gestureRecognizer.location(in: pdfView)
                let pagePoint = pdfView.convert(viewPoint, to: page)
                return annotation.editingBounds
                    .insetBy(dx: -8 / currentPDFScaleFactor, dy: -8 / currentPDFScaleFactor)
                    .contains(pagePoint)
            }
            if gestureRecognizer is UILongPressGestureRecognizer {
                guard gestureRecognizer === imageLongPressGesture,
                      let pdfView,
                      let page = pdfView.page(for: gestureRecognizer.location(in: pdfView), nearest: true) else {
                    return false
                }
                let viewPoint = gestureRecognizer.location(in: pdfView)
                let pagePoint = pdfView.convert(viewPoint, to: page)
                // 삭제 버튼 위의 길게 누름은 이동 편집으로 처리하지 않습니다.
                // 터치를 뗐을 때 전용 삭제 탭이 확실히 주석을 제거하도록 우선권을 줍니다.
                if selectedTool == .image,
                   let selectedImageAnnotation,
                   selectedImageAnnotation.isPortalSelected,
                   selectedImageAnnotation.page === page,
                   selectedImageAnnotation.isDeleteHandleHit(
                    pagePoint,
                    scaleFactor: currentPDFScaleFactor
                   ) {
                    return false
                }
                return editableAnnotation(on: page, point: pagePoint) != nil
            }
            if gestureRecognizer is UIRotationGestureRecognizer {
                return selectedTransformAnnotation != nil
            }
            return true
        }

        /**
         PDFView 기본 스크롤/확대 제스처와 편집 제스처의 동시 인식 여부를 제어합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - gestureRecognizer: 현재 제스처입니다.
            - otherGestureRecognizer: 동시에 발생한 다른 제스처입니다.
         - Returns: 편집 도구가 선택된 경우 PDFView 기본 Pan과 충돌하지 않도록 `false` 입니다.
        */
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === presentationSwipeUpGesture ||
                gestureRecognizer === presentationSwipeDownGesture ||
                otherGestureRecognizer === presentationSwipeUpGesture ||
                otherGestureRecognizer === presentationSwipeDownGesture {
                return true
            }
            if gestureRecognizer === eraserDrawingGesture || otherGestureRecognizer === eraserDrawingGesture {
                let documentGesture = gestureRecognizer === eraserDrawingGesture
                    ? otherGestureRecognizer
                    : gestureRecognizer
                // 지우개는 두 번째 손가락이 감지되면 자체 취소되며, PDF 확대·이동 Gesture는
                // 첫 손가락에서 이미 지우개가 시작됐더라도 동시에 인식할 수 있게 합니다.
                if documentGesture === viewportPinchGesture || documentGesture === viewportPanGesture {
                    return true
                }
            }
            // 펜슬 모드에서 펜 입력을 마친 직후 두 손가락 PDF pan이 이어질 수 있도록
            // 펜 제스처와 PDFView 기본 이동 제스처의 동시 인식을 허용합니다.
            if selectedTool.isInkTool,
               gestureRecognizer === penDrawingGesture || otherGestureRecognizer === penDrawingGesture {
                return true
            }
            return selectedTool == .view
        }

        /// 세 손가락 위·아래 스와이프를 프레젠테이션 제어 UI 표시 이벤트로 전달합니다.
        @objc private func handlePresentationControlSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onPresentationControlsReveal()
        }

        /**
         이미지 또는 도형 Annotation을 길게 눌러 편집 모드로 진입하고 같은 터치로 이동합니다.
         - Version: 1.0.0
         - Date: 2026.07.31
         - Parameters:
            - recognizer: PDFView에서 발생한 Long Press Gesture 입니다.
         */
        @objc private func handleImageLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let pdfView else { return }
            let viewPoint = recognizer.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
            let pagePoint = pdfView.convert(viewPoint, to: page)
            switch recognizer.state {
            case .began:
                guard let annotation = editableAnnotation(on: page, point: pagePoint) else {
                    clearSelectedImageAnnotation()
                    clearSelectedShapeAnnotation()
                    activeImageDragState = nil
                    return
                }
                if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                    selectedTool = .image
                    onActivateImageTool()
                    selectImageAnnotation(imageAnnotation, in: pdfView)
                    handleImageMoveGesture(.began, page: page, point: pagePoint)
                } else if let shapeAnnotation = annotation as? PortalPDFShapeAnnotation {
                    selectedTool = .box
                    onActivateShapeTool()
                    selectShapeAnnotation(shapeAnnotation, in: pdfView)
                    handleShapeMoveGesture(.began, page: page, point: pagePoint)
                }
            case .changed:
                if selectedTool == .image {
                    handleImageMoveGesture(.changed, page: page, point: pagePoint)
                } else if selectedTool == .box {
                    handleShapeMoveGesture(.changed, page: page, point: pagePoint)
                }
            case .ended, .cancelled, .failed:
                if selectedTool == .image {
                    handleImageMoveGesture(recognizer.state, page: page, point: pagePoint)
                } else if selectedTool == .box {
                    handleShapeMoveGesture(recognizer.state, page: page, point: pagePoint)
                }
            default:
                break
            }
        }

        /// 이미지 편집 모드에서 이미지 한 개를 선택하거나, 선택된 이미지의 왼쪽 위 삭제 버튼을 처리합니다.
        @objc private func handleImageTap(_ recognizer: UITapGestureRecognizer) {
            guard selectedTool == .image,
                  recognizer.state == .ended,
                  let pdfView else { return }
            let viewPoint = recognizer.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
            let pagePoint = pdfView.convert(viewPoint, to: page)

            // 삭제 핸들은 이미지 본문 밖에 배치됩니다. 다른 Annotation의 bounds 판정보다
            // 먼저 현재 선택 이미지의 핸들을 확인해야, 보이는 왼쪽 상단 삭제 버튼을
            // 누른 즉시 해당 이미지가 제거됩니다.
            if let selectedImageAnnotation,
               selectedImageAnnotation.page === page,
               selectedImageAnnotation.isPortalSelected,
               selectedImageAnnotation.isDeleteHandleHit(pagePoint, scaleFactor: currentPDFScaleFactor) {
                deleteImageAnnotation(selectedImageAnnotation, from: page, in: pdfView)
                return
            }

            guard let imageAnnotation = editableAnnotation(on: page, point: pagePoint) as? PortalPDFImageAnnotation else {
                clearSelectedImageAnnotation()
                activeImageDragState = nil
                return
            }

            selectImageAnnotation(imageAnnotation, in: pdfView)
        }

        /// 선택 이미지의 왼쪽 상단 삭제 버튼을 누르면 PDF 페이지에서 즉시 제거합니다.
        @objc private func handleSelectedImageDeleteTap(_ recognizer: UITapGestureRecognizer) {
            guard selectedTool == .image,
                  recognizer.state == .ended,
                  let pdfView,
                  let selectedImageAnnotation else { return }
            let viewPoint = recognizer.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true),
                  selectedImageAnnotation.page === page else { return }
            let pagePoint = pdfView.convert(viewPoint, to: page)
            guard selectedImageAnnotation.isPortalSelected,
                  selectedImageAnnotation.isDeleteHandleHit(
                    pagePoint,
                    scaleFactor: currentPDFScaleFactor
                  ) else { return }
            deleteImageAnnotation(selectedImageAnnotation, from: page, in: pdfView)
        }

        /// 박스 편집 모드에서 도형 한 개를 선택하거나, 선택된 도형의 왼쪽 위 삭제 버튼을 처리합니다.
        @objc private func handleShapeTap(_ recognizer: UITapGestureRecognizer) {
            guard selectedTool == .box,
                  recognizer.state == .ended,
                  let pdfView else { return }
            let viewPoint = recognizer.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
            let pagePoint = pdfView.convert(viewPoint, to: page)

            if let selectedShapeAnnotation,
               selectedShapeAnnotation.page === page,
               selectedShapeAnnotation.isPortalSelected,
               selectedShapeAnnotation.isDeleteHandleHit(pagePoint, scaleFactor: currentPDFScaleFactor) {
                deleteShapeAnnotation(selectedShapeAnnotation, from: page, in: pdfView)
                return
            }

            guard let shapeAnnotation = editableAnnotation(on: page, point: pagePoint) as? PortalPDFShapeAnnotation else {
                clearSelectedShapeAnnotation()
                activeImageDragState = nil
                return
            }

            selectShapeAnnotation(shapeAnnotation, in: pdfView)
        }

        /**
         선택된 이미지 Annotation을 회전 제스처 각도에 맞춰 변경합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - recognizer: PDFView에서 발생한 Rotation Gesture 입니다.
         */
        @objc private func handleImageRotation(_ recognizer: UIRotationGestureRecognizer) {
            guard let annotation = selectedTransformAnnotation else { return }
            switch recognizer.state {
            case .began:
                dismissImageActionMenu()
                annotation.rotationAngle += recognizer.rotation
                recognizer.rotation = 0
                if let imageAnnotation = annotation as? PortalPDFImageAnnotation,
                   let page = imageAnnotation.page {
                    refreshImageAnnotationPresentation(imageAnnotation, on: page)
                } else {
                    pdfView?.setNeedsDisplay()
                }
            case .changed:
                annotation.rotationAngle += recognizer.rotation
                recognizer.rotation = 0
                if let imageAnnotation = annotation as? PortalPDFImageAnnotation,
                   let page = imageAnnotation.page {
                    refreshImageAnnotationPresentation(imageAnnotation, on: page)
                } else {
                    pdfView?.setNeedsDisplay()
                }
            case .ended:
                onDocumentChanged()
            default:
                break
            }
        }

        /**
         이미지 편집 모드에서 선택된 이미지를 이동하거나 오른쪽 상단 핸들로 크기와 회전을 변경합니다.
         - Version: 1.0.0
         - Date: 2026.07.31
         - Parameters:
            - state: Pan Gesture 상태입니다.
            - page: 현재 터치가 위치한 PDF Page 입니다.
            - point: PDF Page 좌표계 기준 현재 터치 위치입니다.
         */
        func handleImageMoveGesture(_ state: UIGestureRecognizer.State, page: PDFPage, point: CGPoint) {
            guard let annotation = selectedImageAnnotation, annotation.page === page else {
                activeImageDragState = nil
                return
            }
            handleTransformableAnnotationGesture(state, annotation: annotation, page: page, point: point)
        }

        /// 도형 편집 모드에서 선택된 도형을 이동하거나 8방향 조절점으로 크기를 변경합니다.
        func handleShapeMoveGesture(_ state: UIGestureRecognizer.State, page: PDFPage, point: CGPoint) {
            guard let annotation = selectedShapeAnnotation, annotation.page === page else {
                activeImageDragState = nil
                return
            }
            switch state {
            case .began:
                if let handle = annotation.resizeHandle(at: point, scaleFactor: currentPDFScaleFactor) {
                    activeImageDragState = .resizingBounds(
                        handle: handle,
                        initialBounds: annotation.editingBounds,
                        initialPoint: point
                    )
                } else if PortalPDFEditableAnnotationHitTesting.containsEditingContent(
                    annotation,
                    point: point,
                    padding: 18 / currentPDFScaleFactor
                ) {
                    activeImageDragState = .moving(previousPoint: point)
                } else {
                    activeImageDragState = nil
                }
            case .changed:
                guard let activeImageDragState else { return }
                switch activeImageDragState {
                case .moving(let previousPoint):
                    let delta = CGPoint(x: point.x - previousPoint.x, y: point.y - previousPoint.y)
                    moveAnnotation(annotation, by: delta, on: page)
                    self.activeImageDragState = .moving(previousPoint: point)
                case .resizingBounds(let handle, let initialBounds, let initialPoint):
                    let candidate = resizedEditingBounds(
                        handle: handle,
                        initialBounds: initialBounds,
                        initialPoint: initialPoint,
                        currentPoint: point,
                        rotationAngle: annotation.rotationAngle
                    )
                    annotation.editingBounds = annotation.constrainedEditingBounds(
                        candidate,
                        in: page.bounds(for: .cropBox)
                    )
                    pdfView?.setNeedsDisplay()
                    pdfView?.documentView?.setNeedsDisplay()
                case .transforming:
                    self.activeImageDragState = nil
                }
            case .ended, .cancelled, .failed:
                if activeImageDragState != nil, state == .ended {
                    onDocumentChanged()
                }
                activeImageDragState = nil
            default:
                break
            }
        }

        /// 모서리는 폭·높이를 함께, 변 중앙은 해당 축만 변경하도록 박스 영역을 계산합니다.
        func resizedEditingBounds(
            handle: PortalPDFResizeHandle,
            initialBounds: CGRect,
            initialPoint: CGPoint,
            currentPoint: CGPoint,
            rotationAngle: CGFloat
        ) -> CGRect {
            let center = initialBounds.center
            let cosine = cos(rotationAngle)
            let sine = sin(rotationAngle)
            func unrotated(_ point: CGPoint) -> CGPoint {
                let offset = CGPoint(x: point.x - center.x, y: point.y - center.y)
                return CGPoint(
                    x: center.x + offset.x * cosine + offset.y * sine,
                    y: center.y - offset.x * sine + offset.y * cosine
                )
            }

            let start = unrotated(initialPoint)
            let current = unrotated(currentPoint)
            let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)
            var minX = initialBounds.minX
            var maxX = initialBounds.maxX
            var minY = initialBounds.minY
            var maxY = initialBounds.maxY

            switch handle {
            case .topLeft:
                minX += delta.x
                maxY += delta.y
            case .topCenter:
                maxY += delta.y
            case .topRight:
                maxX += delta.x
                maxY += delta.y
            case .middleLeft:
                minX += delta.x
            case .middleRight:
                maxX += delta.x
            case .bottomLeft:
                minX += delta.x
                minY += delta.y
            case .bottomCenter:
                minY += delta.y
            case .bottomRight:
                maxX += delta.x
                minY += delta.y
            }

            let minimumSide: CGFloat = 32
            if handle == .topLeft || handle == .middleLeft || handle == .bottomLeft {
                minX = min(minX, maxX - minimumSide)
            }
            if handle == .topRight || handle == .middleRight || handle == .bottomRight {
                maxX = max(maxX, minX + minimumSide)
            }
            if handle == .bottomLeft || handle == .bottomCenter || handle == .bottomRight {
                minY = min(minY, maxY - minimumSide)
            }
            if handle == .topLeft || handle == .topCenter || handle == .topRight {
                maxY = max(maxY, minY + minimumSide)
            }

            return CGRect(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )
        }

        /// 이미지와 도형이 공유하는 이동 및 크기·회전 제스처를 처리합니다.
        func handleTransformableAnnotationGesture(
            _ state: UIGestureRecognizer.State,
            annotation: PortalPDFTransformableAnnotation,
            page: PDFPage,
            point: CGPoint
        ) {
            switch state {
            case .began:
                let imageAnnotation = annotation as? PortalPDFImageAnnotation
                if imageAnnotation != nil {
                    dismissImageActionMenu()
                }
                let center = CGPoint(x: annotation.editingBounds.midX, y: annotation.editingBounds.midY)
                let distance = hypot(point.x - center.x, point.y - center.y)
                if let handle = imageAnnotation?.resizeHandle(
                    at: point,
                    scaleFactor: currentPDFScaleFactor
                ) {
                    activeImageDragState = .resizingBounds(
                        handle: handle,
                        initialBounds: annotation.editingBounds,
                        initialPoint: point
                    )
                } else if annotation.isTransformHandleHit(point, scaleFactor: currentPDFScaleFactor), distance > 1 {
                    activeImageDragState = .transforming(
                        previousDistance: distance,
                        previousAngle: atan2(point.y - center.y, point.x - center.x)
                    )
                } else if annotation.editingBounds
                    .insetBy(dx: -18 / currentPDFScaleFactor, dy: -18 / currentPDFScaleFactor)
                    .contains(point) {
                    activeImageDragState = .moving(previousPoint: point)
                } else {
                    activeImageDragState = nil
                }
            case .changed:
                guard let activeImageDragState else { return }
                switch activeImageDragState {
                case .moving(let previousPoint):
                    let delta = CGPoint(x: point.x - previousPoint.x, y: point.y - previousPoint.y)
                    moveAnnotation(annotation, by: delta, on: page)
                    self.activeImageDragState = .moving(previousPoint: point)
                case .transforming(let previousDistance, let previousAngle):
                    let center = CGPoint(x: annotation.editingBounds.midX, y: annotation.editingBounds.midY)
                    let distance = hypot(point.x - center.x, point.y - center.y)
                    guard distance > 1, previousDistance > 1 else {
                        self.activeImageDragState = nil
                        return
                    }
                    let angle = atan2(point.y - center.y, point.x - center.x)
                    scaleAnnotation(annotation, by: distance / previousDistance, on: page)
                    annotation.rotationAngle += normalizedAngle(angle - previousAngle)
                    if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                        refreshImageAnnotationPresentation(imageAnnotation, on: page)
                    } else {
                        pdfView?.setNeedsDisplay()
                    }
                    self.activeImageDragState = .transforming(previousDistance: distance, previousAngle: angle)
                case .resizingBounds(let handle, let initialBounds, let initialPoint):
                    let candidate = resizedEditingBounds(
                        handle: handle,
                        initialBounds: initialBounds,
                        initialPoint: initialPoint,
                        currentPoint: point,
                        rotationAngle: annotation.rotationAngle
                    )
                    annotation.editingBounds = annotation.constrainedEditingBounds(
                        candidate,
                        in: page.bounds(for: .cropBox)
                    )
                    if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                        refreshImageAnnotationPresentation(imageAnnotation, on: page)
                    } else {
                        pdfView?.setNeedsDisplay()
                        pdfView?.documentView?.setNeedsDisplay()
                    }
                }
            case .ended, .cancelled, .failed:
                if activeImageDragState != nil, state == .ended {
                    (annotation as? PortalPDFImageAnnotation)?.prepareForPersistence()
                    onDocumentChanged()
                }
                activeImageDragState = nil
            default:
                break
            }
        }

        /// 현재 도구에서 핀치·회전 편집 중인 이미지 또는 도형입니다.
        var selectedTransformAnnotation: PortalPDFTransformableAnnotation? {
            switch selectedTool {
            case .image:
                return selectedImageAnnotation
            case .box:
                return selectedShapeAnnotation
            default:
                return nil
            }
        }

        /**
         회전 드래그가 ±π 경계를 지날 때 가장 짧은 방향의 각도 변화로 정규화합니다.
         - Version: 1.0.0
         - Date: 2026.07.31
         - Parameters:
            - angle: 정규화할 라디안 각도입니다.
         - Returns: `-π...π` 범위의 라디안 각도입니다.
         */
        func normalizedAngle(_ angle: CGFloat) -> CGFloat {
            var normalized = angle
            while normalized > .pi {
                normalized -= .pi * 2
            }
            while normalized < -.pi {
                normalized += .pi * 2
            }
            return normalized
        }

        /// 센서 압력의 굵기 변화량을 사용자 강도 설정에 맞게 조절합니다.
        func adjustedPenPressure(_ pressure: CGFloat) -> CGFloat {
            let normalizedPressure = min(1, max(0, pressure))
            guard penType == .pressure else { return normalizedPressure }

            // 현재 굵기 공식(0.42 + pressure * 1.58)에서 선택한 기본 굵기가 되는
            // 중립 압력을 기준으로 강도를 늘리거나 줄입니다. 따라서 0%는 고정 굵기,
            // 100%는 기존 반응, 200%는 더 큰 압력 차이를 유지합니다.
            let neutralPressure = (1.0 - 0.42) / 1.58
            let adjusted = neutralPressure
                + (normalizedPressure - neutralPressure) * penPressureStrength
            return min(1, max(0, adjusted))
        }

        /// 한 프레임에 수집된 펜 좌표를 현재 PDF Page 경로와 화면 Overlay 경로에 모두 추가합니다.
        func appendPenSamples<S: Sequence, P: Sequence>(
            _ viewPoints: S,
            pressures: P,
            to page: PDFPage,
            in pdfView: PDFView
        ) where S.Element == CGPoint, P.Element == CGFloat {
            let pairedSamples = Array(zip(viewPoints, pressures))
            // FileManager의 기본 Round Pencil은 이벤트당 마지막 실제 위치 하나를 사용하고
            // 3점마다 곡선 조각을 추가합니다. 압력 펜만 coalesced 좌표 전체를 유지합니다.
            let samples = penType == .pressure ? pairedSamples : Array(pairedSamples.suffix(1))
            var didExtendVisiblePath = false
            for (viewPoint, pressure) in samples {
                // 페이지 사이 여백이나 다른 페이지로 넘어간 좌표는 현재 획에 섞지 않습니다.
                guard pdfView.page(for: viewPoint, nearest: false) === page else { continue }
                if let lastViewPoint = activePenLastViewPoint {
                    let deltaX = viewPoint.x - lastViewPoint.x
                    let deltaY = viewPoint.y - lastViewPoint.y
                    // 너무 가까운 중복점만 제거합니다. 임계값이 크면 원이나 작은 글자의 곡선 샘플이
                    // 빠져 직선 조각처럼 보이므로 0.25pt보다 작은 입력만 제외합니다.
                    guard deltaX * deltaX + deltaY * deltaY >= 0.0625 else { continue }
                }
                let pagePoint = pdfView.convert(viewPoint, to: page)
                let normalizedPressure = adjustedPenPressure(pressure)
                // 센서 압력의 프레임 간 미세 진동을 저역 통과 필터로 완화합니다.
                // 저장과 실시간 Overlay가 같은 값을 사용하므로 손을 뗀 뒤 굵기가 달라지지 않습니다.
                let filteredPressure: CGFloat
                if let previousPressure = activePenPressures.last {
                    filteredPressure = previousPressure * 0.62 + normalizedPressure * 0.38
                } else {
                    filteredPressure = normalizedPressure
                }
                activePenPagePoints.append(pagePoint)
                activePenViewPoints.append(viewPoint)
                activePenPressures.append(filteredPressure)
                if penType == .pressure {
                    activePenPath?.addLine(to: pagePoint)
                    activePenOverlayPath?.addLine(to: viewPoint)
                    didExtendVisiblePath = true
                } else {
                    didExtendVisiblePath = appendFileManagerRoundedPenSample(
                        pagePoint: pagePoint,
                        viewPoint: viewPoint
                    ) || didExtendVisiblePath
                }
                activePenLastViewPoint = viewPoint
                activePenSampleCount += 1
            }
            if didExtendVisiblePath, penType != .pressure {
                refreshActivePenOverlay()
            }
        }

        /// FileManager `newLineDrawing`의 3점 Cubic 연결을 페이지/화면 경로에 동시에 적용합니다.
        @discardableResult
        func appendFileManagerRoundedPenSample(pagePoint: CGPoint, viewPoint: CGPoint) -> Bool {
            activePenCurveIndex += 1
            guard activePenCurveIndex < activePenPageCurvePoints.count else { return false }
            activePenPageCurvePoints[activePenCurveIndex] = pagePoint
            activePenViewCurvePoints[activePenCurveIndex] = viewPoint
            guard activePenCurveIndex == 3 else { return false }

            let pageMidpoint = CGPoint(
                x: (activePenPageCurvePoints[1].x + activePenPageCurvePoints[3].x) / 2,
                y: (activePenPageCurvePoints[1].y + activePenPageCurvePoints[3].y) / 2
            )
            let viewMidpoint = CGPoint(
                x: (activePenViewCurvePoints[1].x + activePenViewCurvePoints[3].x) / 2,
                y: (activePenViewCurvePoints[1].y + activePenViewCurvePoints[3].y) / 2
            )
            activePenPath?.move(to: activePenPageCurvePoints[0])
            activePenPath?.addCurve(
                to: pageMidpoint,
                controlPoint1: activePenPageCurvePoints[0],
                controlPoint2: activePenPageCurvePoints[1]
            )
            activePenOverlayPath?.move(to: activePenViewCurvePoints[0])
            activePenOverlayPath?.addCurve(
                to: viewMidpoint,
                controlPoint1: activePenViewCurvePoints[0],
                controlPoint2: activePenViewCurvePoints[1]
            )
            activePenPageCurvePoints[0] = pageMidpoint
            activePenPageCurvePoints[1] = activePenPageCurvePoints[3]
            activePenViewCurvePoints[0] = viewMidpoint
            activePenViewCurvePoints[1] = activePenViewCurvePoints[3]
            activePenCurveIndex = 1
            return true
        }

        /// 손을 뗄 때 남은 두 좌표를 FileManager `endLineDrawing`과 같은 곡선으로 마감합니다.
        func finishFileManagerRoundedPenPath() {
            // UIGestureRecognizer의 ended 좌표가 마지막 moved 좌표와 같으면 중복 필터를 통과하지
            // 않습니다. FileManager는 ended에서도 `newLineDrawing`을 한 번 호출하므로 그 동작과
            // 같게 마지막 좌표를 복제해 짧은 획과 마지막 꼬리를 빠뜨리지 않습니다.
            if activePenCurveIndex == 1 {
                activePenPageCurvePoints[2] = activePenPageCurvePoints[1]
                activePenViewCurvePoints[2] = activePenViewCurvePoints[1]
                activePenCurveIndex = 2
            }
            guard activePenCurveIndex == 2 else { return }
            let pageMidpoint = CGPoint(
                x: (activePenPageCurvePoints[0].x + activePenPageCurvePoints[2].x) / 2,
                y: (activePenPageCurvePoints[0].y + activePenPageCurvePoints[2].y) / 2
            )
            let viewMidpoint = CGPoint(
                x: (activePenViewCurvePoints[0].x + activePenViewCurvePoints[2].x) / 2,
                y: (activePenViewCurvePoints[0].y + activePenViewCurvePoints[2].y) / 2
            )
            activePenPath?.move(to: activePenPageCurvePoints[0])
            activePenPath?.addCurve(
                to: activePenPageCurvePoints[2],
                controlPoint1: activePenPageCurvePoints[0],
                controlPoint2: pageMidpoint
            )
            activePenOverlayPath?.move(to: activePenViewCurvePoints[0])
            activePenOverlayPath?.addCurve(
                to: activePenViewCurvePoints[2],
                controlPoint1: activePenViewCurvePoints[0],
                controlPoint2: viewMidpoint
            )
        }

        /// 라인 보정이 켜진 경우에만 원본 좌표를 보정해 FileManager cubic 경로로 다시 구성합니다.
        func applyLineCorrectionToFileManagerPathsIfNeeded() {
            guard penStrokeSmoothingStrength > 0,
                  let activePenPath,
                  let activePenOverlayPath else { return }

            let correctedPagePoints = activePenPagePoints.terminalFlickStabilized(
                strength: penStrokeSmoothingStrength
            )
            let correctedViewPoints = activePenViewPoints.terminalFlickStabilized(
                strength: penStrokeSmoothingStrength
            )
            guard let correctedPagePath = makeFileManagerRoundedPath(points: correctedPagePoints),
                  let correctedViewPath = makeFileManagerRoundedPath(points: correctedViewPoints) else {
                return
            }

            activePenPath.removeAllPoints()
            activePenPath.append(correctedPagePath)
            activePenOverlayPath.removeAllPoints()
            activePenOverlayPath.append(correctedViewPath)
        }

        /// FileManager의 3점 cubic 연결 규칙으로 좌표 배열을 하나의 경로로 변환합니다.
        func makeFileManagerRoundedPath(points: [CGPoint]) -> UIBezierPath? {
            guard let firstPoint = points.first else { return nil }
            let path = makeRoundedPath(startPoint: firstPoint)
            guard points.count > 1 else { return path }

            var curvePoints = [CGPoint](repeating: .zero, count: 4)
            curvePoints[0] = firstPoint
            var curveIndex = 0
            for point in points.dropFirst() {
                curveIndex += 1
                curvePoints[curveIndex] = point
                guard curveIndex == 3 else { continue }

                let midpoint = CGPoint(
                    x: (curvePoints[1].x + curvePoints[3].x) / 2,
                    y: (curvePoints[1].y + curvePoints[3].y) / 2
                )
                path.move(to: curvePoints[0])
                path.addCurve(
                    to: midpoint,
                    controlPoint1: curvePoints[0],
                    controlPoint2: curvePoints[1]
                )
                curvePoints[0] = midpoint
                curvePoints[1] = curvePoints[3]
                curveIndex = 1
            }

            if curveIndex == 1 {
                curvePoints[2] = curvePoints[1]
                curveIndex = 2
            }
            if curveIndex == 2 {
                let midpoint = CGPoint(
                    x: (curvePoints[0].x + curvePoints[2].x) / 2,
                    y: (curvePoints[0].y + curvePoints[2].y) / 2
                )
                path.move(to: curvePoints[0])
                path.addCurve(
                    to: curvePoints[2],
                    controlPoint1: curvePoints[0],
                    controlPoint2: midpoint
                )
            }
            return path
        }

        /// 이동이 거의 없는 짧은 한글 획도 둥근 점으로 표시되도록 최소 길이를 추가합니다.
        func ensureVisibleDotIfNeeded(pagePath: UIBezierPath) {
            guard activePenSampleCount == 1 else { return }
            let pagePoint = pagePath.currentPoint
            let pageDotLength = max(0.01, penLineWidth * 0.02)
            pagePath.addLine(to: CGPoint(x: pagePoint.x + pageDotLength, y: pagePoint.y))
            if let overlayPath = activePenOverlayPath {
                let viewPoint = overlayPath.currentPoint
                overlayPath.addLine(to: CGPoint(
                    x: viewPoint.x + pageDotLength * currentPDFScaleFactor,
                    y: viewPoint.y
                ))
            }
            activePenSampleCount += 1
        }

        /**
         박스 도구의 시작/이동/종료 상태를 실시간 Overlay와 최종 PDF Square Annotation으로 변환합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - state: Pan Gesture 상태입니다.
            - page: 박스 주석을 추가할 PDF Page 입니다.
            - pagePoint: PDF Page 좌표계 기준 터치 지점입니다.
            - viewPoint: PDFView 좌표계 기준 터치 지점입니다.
         */
        func handleBoxGesture(_ state: UIGestureRecognizer.State, page: PDFPage, pagePoint: CGPoint, viewPoint: CGPoint) {
            switch state {
            case .began:
                activeBoxPage = page
                activeBoxStartPoint = pagePoint
                activeBoxStartViewPoint = viewPoint
                refreshActiveBoxOverlay(to: viewPoint)
            case .changed:
                guard activeBoxPage === page else { return }
                refreshActiveBoxOverlay(to: viewPoint)
            case .ended:
                guard activeBoxPage === page, let startPoint = activeBoxStartPoint else { resetActiveDrawing(); return }
                addBoxAnnotation(from: startPoint, to: pagePoint, on: page)
                resetActiveDrawing()
                onDocumentChanged()
            case .cancelled, .failed:
                resetActiveDrawing()
            default:
                break
            }
        }

        /**
         지우개 도구의 드래그 상태를 처리하여 지나가는 위치의 주석을 삭제합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - state: Pan Gesture 상태입니다.
            - page: 지우개가 동작할 PDF Page 입니다.
            - point: PDF Page 좌표계 기준 현재 지우개 위치입니다.
         */
        func handleEraseGesture(_ state: UIGestureRecognizer.State, page: PDFPage, point: CGPoint) {
            switch state {
            case .began:
                activeEraserPage = page
                activeEraserLastPoint = point
                activeEraserDidMutate = false
                activeEraserPressureAnnotations.removeAll(keepingCapacity: true)
                enqueueEraserSegment(on: page, from: point, to: point)
            case .changed:
                guard activeEraserPage === page else {
                    activeEraserPage = page
                    activeEraserLastPoint = point
                    enqueueEraserSegment(on: page, from: point, to: point)
                    return
                }
                enqueueEraserSegment(on: page, from: activeEraserLastPoint ?? point, to: point)
                activeEraserLastPoint = point
            case .ended:
                if activeEraserPage === page {
                    enqueueEraserSegment(on: page, from: activeEraserLastPoint ?? point, to: point)
                } else {
                    enqueueEraserSegment(on: page, from: point, to: point)
                }
                if let pdfView { finishEraserGesture(in: pdfView) }
            case .cancelled, .failed:
                if let pdfView { finishEraserGesture(in: pdfView) }
            default:
                break
            }
        }

        /// 남은 삭제 구간을 즉시 확정하고 한 번만 전체 화면 갱신·자동 저장을 요청합니다.
        func finishEraserGesture(in _: PDFView) {
            processPendingEraserSegments()
            if activeEraserDidMutate {
                activeEraserPressureAnnotations.forEach { annotation in
                    guard annotation.page != nil else { return }
                    annotation.prepareForPersistence()
                }
                // 드래그 중 변경 영역은 이미 부분 갱신했습니다. 손을 떼는 순간 모든 PDF 타일을
                // 다시 그리면 확대·이동이 잠시 멈추므로 저장 요청만 전달합니다.
                onDocumentChanged()
            }
            activeEraserPressureAnnotations.removeAll(keepingCapacity: true)
            activeEraserDidMutate = false
            activeEraserLastPoint = nil
            activeEraserPage = nil
            hideEraserOverlay()
        }

        /// Undo/Redo가 PDF Annotation을 교체하기 전에 진행 중인 지우개 입력을 안전하게 종료합니다.
        func finishActiveEraserBeforeHistory(in pdfView: PDFView) {
            if let recognizer = eraserDrawingGesture,
               recognizer.state == .began || recognizer.state == .changed {
                // 비활성화 시 cancelled 이벤트가 동기 전달되어 남은 좌표가 먼저 확정됩니다.
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }

            // Gesture가 이미 ended 상태여도 다음 30fps 프레임에 남은 좌표가 있을 수 있습니다.
            finishEraserGesture(in: pdfView)
            eraserProcessingWorkItem?.cancel()
            eraserProcessingWorkItem = nil
            pendingEraserSegments.removeAll(keepingCapacity: true)
        }

        /// 연속 지우개 구간을 다음 30fps 처리 프레임에 합칩니다.
        func enqueueEraserSegment(on page: PDFPage, from start: CGPoint, to end: CGPoint) {
            pendingEraserSegments.append(.init(page: page, start: start, end: end))
            guard eraserProcessingWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.processPendingEraserSegments()
            }
            eraserProcessingWorkItem = workItem
            // 전용 Gesture가 커서를 즉시 이동시키고, 삭제 계산은 화면 주사율보다 낮은
            // 30fps 단위로 합쳐 동일 Annotation 경로를 과도하게 반복 계산하지 않습니다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0, execute: workItem)
        }

        /// 한 프레임 동안 수집한 구간을 페이지별 좌표 배열로 합쳐 주석 검색·경로 교체를 한 번만 수행합니다.
        func processPendingEraserSegments() {
            eraserProcessingWorkItem?.cancel()
            eraserProcessingWorkItem = nil
            let segments = pendingEraserSegments
            pendingEraserSegments.removeAll(keepingCapacity: true)
            guard !isApplyingHistory, !segments.isEmpty, let pdfView else { return }

            var pageOrder: [ObjectIdentifier] = []
            var pages: [ObjectIdentifier: PDFPage] = [:]
            var pointsByPage: [ObjectIdentifier: [CGPoint]] = [:]
            let eraserRadius = eraserSize / currentPDFScaleFactor
            for segment in segments {
                let identifier = ObjectIdentifier(segment.page)
                if pages[identifier] == nil {
                    pageOrder.append(identifier)
                    pages[identifier] = segment.page
                }
                pointsByPage[identifier, default: []].append(contentsOf: sampledEraserPoints(
                    from: segment.start,
                    to: segment.end,
                    radius: eraserRadius
                ))
            }

            var didMutate = false
            var dirtyViewRects: [CGRect] = []
            for identifier in pageOrder {
                guard let page = pages[identifier], let points = pointsByPage[identifier] else { continue }
                let pageDidMutate = eraseAnnotations(on: page, along: points, baseRadius: eraserRadius)
                didMutate = pageDidMutate || didMutate
                if pageDidMutate,
                   let pointBounds = points.boundingRect {
                    let dirtyPageRect = pointBounds.insetBy(
                        dx: -(eraserRadius * 1.5),
                        dy: -(eraserRadius * 1.5)
                    )
                    dirtyViewRects.append(pdfView.convert(dirtyPageRect, from: page))
                }
            }
            guard didMutate else { return }
            activeEraserDidMutate = true
            pageOrder.compactMap { pages[$0] }.forEach { page in
                refreshPersistentAnnotationOverlay(on: page)
            }
            refreshPDFViewDuringEraser(in: pdfView, dirtyViewRects: dirtyViewRects)
        }

        func sampledEraserPoints(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> [CGPoint] {
            let distance = sqrt(distanceSquared(start, end))
            // 인접 원이 겹치는 0.75R 간격으로 기존 삭제 범위는 유지하면서 계산 좌표 수를 줄입니다.
            let step = max(2, radius * 0.75)
            let sampleCount = max(1, Int(ceil(distance / step)))
            return (1...sampleCount).map { index in
                let progress = CGFloat(index) / CGFloat(sampleCount)
                return CGPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                )
            }
        }

        /// 보간된 지우개 좌표를 Annotation별로 묶어 처리해 전체 검색과 PDF 갱신 반복을 줄입니다.
        func eraseAnnotations(
            on page: PDFPage,
            along points: [CGPoint],
            baseRadius: CGFloat
        ) -> Bool {
            guard !points.isEmpty else { return false }
            let annotationSnapshot = Array(page.annotations.reversed())
            var didErase = false

            // 일반 Ink는 Annotation 하나의 모든 지우개 좌표를 메모리에서 먼저 반영하고
            // PDFKit 경로 교체는 단 한 번만 수행합니다.
            for annotation in annotationSnapshot
            where annotation.isPortalInkAnnotation
                && !PortalPDFPressureInkAnnotation.isPressureInk(annotation) {
                let hitExpansion = baseRadius + eraserHitExpansion(for: annotation)
                let hitPoints = points.filter {
                    annotation.bounds.insetBy(dx: -hitExpansion, dy: -hitExpansion).contains($0)
                }
                guard !hitPoints.isEmpty else { continue }
                didErase = eraseStandardInkAnnotation(
                    annotation,
                    on: page,
                    points: hitPoints,
                    baseRadius: baseRadius
                ) || didErase
            }

            // 압력선도 한 프레임의 모든 지우개 좌표를 메모리에서 먼저 반영합니다.
            // 앱에서 생성한 압력선은 동일 Annotation 객체를 유지해 PDFKit 객체·타일 캐시 증가를 막습니다.
            let pressureAnnotations = annotationSnapshot.filter {
                PortalPDFPressureInkAnnotation.isPressureInk($0)
            }
            for annotation in pressureAnnotations {
                let expansion = baseRadius + eraserHitExpansion(for: annotation)
                let hitPoints = points.filter { point in
                    annotation.bounds.insetBy(dx: -expansion, dy: -expansion).contains(point)
                }
                guard !hitPoints.isEmpty else { continue }
                didErase = erasePressureInkAnnotation(
                    annotation,
                    on: page,
                    points: hitPoints,
                    baseRadius: baseRadius
                ) || didErase
            }
            return didErase
        }

        func erasePressureInkAnnotation(
            _ annotation: PDFAnnotation,
            on page: PDFPage,
            points: [CGPoint],
            baseRadius: CGFloat
        ) -> Bool {
            if let pressureAnnotation = annotation as? PortalPDFPressureInkAnnotation {
                switch pressureAnnotation.eraseStrokeFragments(
                    around: points,
                    eraserRadius: baseRadius
                ) {
                case .unchanged:
                    return false
                case .updated:
                    if !activeEraserPressureAnnotations.contains(where: { $0 === pressureAnnotation }) {
                        activeEraserPressureAnnotations.append(pressureAnnotation)
                    }
                    return true
                case .removed:
                    pressureAnnotation.shouldDisplay = false
                    pressureAnnotation.shouldPrint = false
                    page.removeAnnotation(pressureAnnotation)
                    return true
                }
            }

            guard let fragments = PortalPDFPressureInkAnnotation.fragmentsAfterErasing(
                annotation,
                around: points,
                eraserRadius: baseRadius
            ) else { return false }
            if fragments.isEmpty {
                annotation.shouldDisplay = false
                annotation.shouldPrint = false
                page.removeAnnotation(annotation)
                return true
            }
            // 저장 후 다시 불러온 표준 Stamp는 최초 지우기 때만 편집 가능한 객체로 교체합니다.
            // 이후 연속 삭제는 위 분기에서 같은 객체 내부 경로만 변경합니다.
            let baseLineWidth = PortalPDFPressureInkAnnotation.storedBaseLineWidth(in: annotation)
                ?? penLineWidth
            let color = PortalPDFPressureInkAnnotation.storedColor(in: annotation)
            annotation.shouldDisplay = false
            annotation.shouldPrint = false
            page.removeAnnotation(annotation)
            if let groupedAnnotation = PortalPDFPressureInkAnnotation.groupedAnnotation(
                fragments: fragments,
                baseLineWidth: baseLineWidth,
                color: color
            ) {
                page.addAnnotation(groupedAnnotation)
            }
            return true
        }

        /**
         지우개 위치와 겹치는 PDF Annotation을 찾아 삭제합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - page: 삭제 대상 주석을 찾을 PDF Page 입니다.
            - point: PDF Page 좌표계 기준 지우개 위치입니다.
         */
        @discardableResult
        func eraseAnnotationIfNeeded(on page: PDFPage, point: CGPoint) -> Bool {
            let baseEraserRadius = eraserSize / currentPDFScaleFactor
            let directlyHitAnnotations = page.annotations.reversed().filter { annotation in
                guard isErasableAnnotation(annotation) else { return false }
                let hitExpansion = baseEraserRadius + eraserHitExpansion(for: annotation)
                guard annotation.bounds.insetBy(dx: -hitExpansion, dy: -hitExpansion).contains(point) else {
                    return false
                }
                if PortalPDFPressureInkAnnotation.isPressureInk(annotation) {
                    return PortalPDFPressureInkAnnotation.containsStroke(
                        in: annotation,
                        point: point,
                        extraRadius: baseEraserRadius
                    )
                }
                return standardInkContainsStroke(
                    annotation,
                    point: point,
                    extraRadius: baseEraserRadius
                )
            }

            var didErase = false
            for annotation in directlyHitAnnotations {
                didErase = eraseInkAnnotation(
                    annotation,
                    on: page,
                    point: point,
                    baseRadius: baseEraserRadius
                ) || didErase
            }

            if !didErase,
               let nearestAnnotation = nearestAnnotation(on: page, point: point),
               !directlyHitAnnotations.contains(where: { $0 === nearestAnnotation }) {
                didErase = eraseInkAnnotation(
                    nearestAnnotation,
                    on: page,
                    point: point,
                    baseRadius: baseEraserRadius
                )
            }

            guard didErase, let pdfView else { return false }
            // Stamp 기반 압력 획은 shouldDisplay를 먼저 끈 뒤 Annotation 레이어를 즉시 무효화해야
            // PDFKit 타일 캐시에 삭제 전 외곽선이 남지 않습니다.
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
            return true
        }

        func eraseInkAnnotation(
            _ annotation: PDFAnnotation,
            on page: PDFPage,
            point: CGPoint,
            baseRadius: CGFloat
        ) -> Bool {
            if PortalPDFPressureInkAnnotation.isPressureInk(annotation) {
                return erasePressureInkAnnotation(
                    annotation,
                    on: page,
                    points: [point],
                    baseRadius: baseRadius
                )
            }
            return eraseStandardInkAnnotation(
                annotation,
                on: page,
                points: [point],
                baseRadius: baseRadius
            )
        }

        /// 일반 Ink Annotation에 여러 지우개 좌표를 누적 적용한 뒤 경로를 한 번만 교체합니다.
        func eraseStandardInkAnnotation(
            _ annotation: PDFAnnotation,
            on page: PDFPage,
            points: [CGPoint],
            baseRadius: CGFloat
        ) -> Bool {
            guard let inkPaths = annotation.paths, !inkPaths.isEmpty else {
                page.removeAnnotation(annotation)
                return true
            }

            let eraserRadius = baseRadius + eraserHitExpansion(for: annotation)
            let annotationOrigin = annotation.bounds.origin
            var remainingPaths = inkPaths
            var didErase = false
            for point in points where !remainingPaths.isEmpty {
                let localPoint = CGPoint(
                    x: point.x - annotationOrigin.x,
                    y: point.y - annotationOrigin.y
                )
                remainingPaths = remainingPaths.flatMap { path -> [UIBezierPath] in
                    guard path.bounds.insetBy(dx: -eraserRadius, dy: -eraserRadius).contains(localPoint) else {
                        return [path]
                    }
                    let result = clippedInkPaths(path, around: localPoint, radius: eraserRadius)
                    didErase = didErase || result.didErase
                    return result.paths
                }
            }
            guard didErase else { return false }

            if remainingPaths.isEmpty {
                page.removeAnnotation(annotation)
            } else {
                let preservedColor = annotation.color
                let preservedBorderWidth = annotation.border?.lineWidth ?? penLineWidth
                inkPaths.forEach { annotation.remove($0) }
                remainingPaths.forEach { annotation.add($0) }
                // PDFKit이 Ink 경로를 교체할 때 색상·알파값을 기본값으로 되돌리는 경우가 있어
                // 형광펜의 원래 반투명 색상과 선 두께를 다시 명시합니다.
                annotation.color = preservedColor
                let border = PDFBorder()
                border.lineWidth = preservedBorderWidth
                annotation.border = border
            }
            return true
        }

        func clippedInkPaths(_ path: UIBezierPath, around center: CGPoint, radius: CGFloat) -> (paths: [UIBezierPath], didErase: Bool) {
            let points = inkPoints(from: path)
            guard points.count > 1 else {
                let didErase = path.bounds.insetBy(dx: -radius, dy: -radius).contains(center)
                return (didErase ? [] : [path], didErase)
            }

            var clippedPaths: [UIBezierPath] = []
            var currentPath: UIBezierPath?
            var didErase = false
            let originalLineCapStyle = path.lineCapStyle

            for index in 0..<(points.count - 1) {
                let start = points[index]
                let end = points[index + 1]
                let intervals = outsideIntervals(from: start, to: end, center: center, radius: radius)
                if intervals.count != 1 || intervals.first?.0 != 0 || intervals.first?.1 != 1 {
                    didErase = true
                }
                for (startT, endT) in intervals where endT - startT > 0.001 {
                    let clippedStart = interpolate(start, end, at: startT)
                    let clippedEnd = interpolate(start, end, at: endT)

                    if let activePath = currentPath,
                       distanceSquared(activePath.currentPoint, clippedStart) > 0.001 {
                        clippedPaths.append(activePath)
                        configureClippedInkPath(activePath, lineCapStyle: originalLineCapStyle)
                        currentPath = nil
                    }

                    if currentPath == nil {
                        currentPath = makeRoundedPath(startPoint: clippedStart)
                    }
                    currentPath?.addLine(to: clippedEnd)

                    // 지워진 구간 뒤의 선분은 이전 선분과 같은 경로로 이어지면 안 됩니다.
                    if endT < 0.999 {
                        if let activePath = currentPath {
                            clippedPaths.append(activePath)
                            configureClippedInkPath(activePath, lineCapStyle: originalLineCapStyle)
                        }
                        currentPath = nil
                    }
                }

                // 현재 선분 전체가 지워졌다면 직전까지 이어진 경로를 닫습니다.
                if intervals.isEmpty, let activePath = currentPath {
                    clippedPaths.append(activePath)
                    configureClippedInkPath(activePath, lineCapStyle: originalLineCapStyle)
                    currentPath = nil
                }
            }

            if let currentPath = currentPath {
                clippedPaths.append(currentPath)
                configureClippedInkPath(currentPath, lineCapStyle: originalLineCapStyle)
            }

            return (clippedPaths, didErase)
        }

        func configureClippedInkPath(_ path: UIBezierPath, lineCapStyle: CGLineCap = .round) {
            path.lineCapStyle = lineCapStyle
            path.lineJoinStyle = .round
            path.flatness = 0.6
        }

        /// PDF Ink 중심선이 아니라 실제 선 두께까지 지우개 판정에 포함합니다.
        func eraserHitExpansion(for annotation: PDFAnnotation) -> CGFloat {
            if let baseLineWidth = PortalPDFPressureInkAnnotation.storedBaseLineWidth(in: annotation) {
                return PortalPDFVariableWidthStroke.lineWidth(
                    for: 1,
                    baseLineWidth: baseLineWidth
                ) / 2
            }
            let lineWidth = annotation.border?.lineWidth ?? 0
            return max(0, lineWidth / 2)
        }

        /// 다중 경로 Ink의 넓은 Annotation bounds 대신 실제 선 외곽으로 지우개 명중을 판정합니다.
        func standardInkContainsStroke(
            _ annotation: PDFAnnotation,
            point: CGPoint,
            extraRadius: CGFloat
        ) -> Bool {
            guard let paths = annotation.paths, !paths.isEmpty else { return false }
            let localPoint = CGPoint(
                x: point.x - annotation.bounds.minX,
                y: point.y - annotation.bounds.minY
            )
            let lineWidth = annotation.border?.lineWidth ?? 1
            let hitWidth = max(0.5, lineWidth + extraRadius * 2)
            return paths.contains { path in
                let pathRadius = hitWidth / 2
                guard path.bounds.insetBy(dx: -pathRadius, dy: -pathRadius).contains(localPoint) else {
                    return false
                }
                let strokedPath = path.cgPath.copy(
                    strokingWithWidth: hitWidth,
                    lineCap: path.lineCapStyle,
                    lineJoin: path.lineJoinStyle,
                    miterLimit: path.miterLimit,
                    transform: .identity
                )
                return strokedPath.contains(localPoint)
            }
        }

        func inkPoints(from path: UIBezierPath) -> [CGPoint] {
            var points: [CGPoint] = []
            var currentPoint: CGPoint?
            var subpathStartPoint: CGPoint?
            let cgPath = path.cgPath
            cgPath.applyWithBlock { elementPointer in
                appendInkPoints(
                    from: elementPointer.pointee,
                    points: &points,
                    currentPoint: &currentPoint,
                    subpathStartPoint: &subpathStartPoint
                )
            }
            return points
        }

        func appendInkPoints(
            from element: CGPathElement,
            points: inout [CGPoint],
            currentPoint: inout CGPoint?,
            subpathStartPoint: inout CGPoint?
        ) {
            switch element.type {
            case .moveToPoint:
                let point = element.points[0]
                points.append(point)
                currentPoint = point
                subpathStartPoint = point
            case .addLineToPoint:
                let point = element.points[0]
                points.append(point)
                currentPoint = point
            case .addQuadCurveToPoint:
                guard let start = currentPoint else { return }
                let control = element.points[0]
                let end = element.points[1]
                for step in 1...12 {
                    let t = CGFloat(step) / 12
                    let inverse = 1 - t
                    points.append(CGPoint(
                        x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
                        y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
                    ))
                }
                currentPoint = end
            case .addCurveToPoint:
                guard let start = currentPoint else { return }
                let firstControl = element.points[0]
                let secondControl = element.points[1]
                let end = element.points[2]
                for step in 1...16 {
                    let t = CGFloat(step) / 16
                    let inverse = 1 - t
                    points.append(CGPoint(
                        x: inverse * inverse * inverse * start.x
                            + 3 * inverse * inverse * t * firstControl.x
                            + 3 * inverse * t * t * secondControl.x
                            + t * t * t * end.x,
                        y: inverse * inverse * inverse * start.y
                            + 3 * inverse * inverse * t * firstControl.y
                            + 3 * inverse * t * t * secondControl.y
                            + t * t * t * end.y
                    ))
                }
                currentPoint = end
            case .closeSubpath:
                if let subpathStartPoint {
                    points.append(subpathStartPoint)
                    currentPoint = subpathStartPoint
                }
            @unknown default:
                break
            }
        }

        /// 한 점에서 Ink 중심선을 구성하는 모든 선분까지의 최소 거리 제곱을 반환합니다.
        func minimumDistanceSquared(from point: CGPoint, to pathPoints: [CGPoint]) -> CGFloat {
            guard let firstPoint = pathPoints.first else { return .greatestFiniteMagnitude }
            guard pathPoints.count > 1 else { return distanceSquared(point, firstPoint) }
            var minimumDistance = CGFloat.greatestFiniteMagnitude
            for index in 0..<(pathPoints.count - 1) {
                minimumDistance = min(
                    minimumDistance,
                    distanceSquared(from: point, toSegmentFrom: pathPoints[index], to: pathPoints[index + 1])
                )
            }
            return minimumDistance
        }

        /// 한 점에서 지정한 선분까지의 최단 거리 제곱을 계산합니다.
        func distanceSquared(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let segmentLengthSquared = deltaX * deltaX + deltaY * deltaY
            guard segmentLengthSquared > 0.0001 else { return distanceSquared(point, start) }
            let projection = ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / segmentLengthSquared
            let clampedProjection = max(0, min(1, projection))
            let nearestPoint = CGPoint(
                x: start.x + deltaX * clampedProjection,
                y: start.y + deltaY * clampedProjection
            )
            return distanceSquared(point, nearestPoint)
        }

        func outsideIntervals(from start: CGPoint, to end: CGPoint, center: CGPoint, radius: CGFloat) -> [(CGFloat, CGFloat)] {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let fx = start.x - center.x
            let fy = start.y - center.y
            let a = dx * dx + dy * dy

            guard a > 0.0001 else {
                return distanceSquared(start, center) > radius * radius ? [(0, 1)] : []
            }

            let b = 2 * (fx * dx + fy * dy)
            let c = fx * fx + fy * fy - radius * radius
            let discriminant = b * b - 4 * a * c
            guard discriminant > 0 else {
                return c > 0 ? [(0, 1)] : []
            }

            let root = sqrt(discriminant)
            let first = max(0, min(1, (-b - root) / (2 * a)))
            let second = max(0, min(1, (-b + root) / (2 * a)))
            let cuts = Array(Set([CGFloat(0), first, second, CGFloat(1)])).sorted()
            var intervals: [(CGFloat, CGFloat)] = []

            for index in 0..<(cuts.count - 1) {
                let startT = cuts[index]
                let endT = cuts[index + 1]
                let midpoint = interpolate(start, end, at: (startT + endT) / 2)
                if distanceSquared(midpoint, center) > radius * radius {
                    intervals.append((startT, endT))
                }
            }
            return intervals
        }

        func interpolate(_ start: CGPoint, _ end: CGPoint, at t: CGFloat) -> CGPoint {
            CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }

        func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
            let dx = lhs.x - rhs.x
            let dy = lhs.y - rhs.y
            return dx * dx + dy * dy
        }

        /// 지우개가 제거할 수 있는 Annotation인지 확인합니다. 펜으로 만든 Ink 주석만 삭제합니다.
        func isErasableAnnotation(_ annotation: PDFAnnotation) -> Bool {
            annotation.isPortalInkAnnotation || PortalPDFPressureInkAnnotation.isPressureInk(annotation)
        }

        /**
         PDF Page 좌표계 또는 PDFView 좌표계에서 사용할 둥근 자유선 경로를 생성합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - startPoint: 자유선 시작 좌표입니다.
         - Returns: 선 끝과 꺾임이 둥근 UIBezierPath 입니다.
         */
        func makeRoundedPath(startPoint: CGPoint) -> UIBezierPath {
            let path = UIBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.flatness = 0.6
            path.move(to: startPoint)
            return path
        }

        /// 연속 터치 이벤트의 경로 재계산을 화면 주기당 한 번으로 합칩니다.
        func scheduleActivePenOverlayRefresh() {
            guard activePenOverlayPath != nil else { return }
            activePenOverlayNeedsRefresh = true
            guard activePenOverlayDisplayLink == nil else { return }

            let displayLink = CADisplayLink(
                target: self,
                selector: #selector(processScheduledActivePenOverlayRefresh)
            )
            if #available(iOS 15.0, *) {
                displayLink.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 30,
                    maximum: 60,
                    preferred: 60
                )
            } else {
                displayLink.preferredFramesPerSecond = 60
            }
            displayLink.add(to: .main, forMode: .common)
            activePenOverlayDisplayLink = displayLink
        }

        /// 화면 갱신 시점에 최신 입력 전체를 한 번만 보정해 표시합니다.
        @objc func processScheduledActivePenOverlayRefresh() {
            guard activePenOverlayNeedsRefresh else { return }
            activePenOverlayNeedsRefresh = false
            refreshActivePenOverlay()
        }

        /// 펜을 놓기 직전 대기 중인 마지막 입력까지 보정된 화면에 즉시 반영합니다.
        func flushActivePenOverlayRefresh() {
            activePenOverlayNeedsRefresh = false
            refreshActivePenOverlay()
        }

        /// 획이 끝나거나 PDF 화면을 닫을 때 화면 갱신 타이머를 정리합니다.
        func stopActivePenOverlayRefresh() {
            activePenOverlayDisplayLink?.invalidate()
            activePenOverlayDisplayLink = nil
            activePenOverlayNeedsRefresh = false
        }

        /**
         펜 드래그 중 PDFView 위에 올린 Shape Layer 경로를 갱신합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         */
        func refreshActivePenOverlay() {
            guard let activePenOverlayPath else { return }
            if penType == .pressure {
                activePenOverlayLayer?.isHidden = true
                refreshPressurePenOverlay()
                return
            }

            activePressureOverlayLayer?.removeFromSuperlayer()
            activePressureOverlayLayer = nil
            let overlayLayer = activePenOverlayLayer ?? makePenOverlayLayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let targetFrame = pdfView?.bounds ?? .zero
            if overlayLayer.frame != targetFrame {
                overlayLayer.frame = targetFrame
            }
            overlayLayer.isHidden = false
            overlayLayer.lineWidth = penLineWidth * currentPDFScaleFactor
            if selectedTool == .neon {
                overlayLayer.strokeColor = neonCoreColor(for: penColor).cgColor
                overlayLayer.shadowColor = penColor.cgColor
                overlayLayer.shadowOpacity = 1
                overlayLayer.shadowRadius = max(5, penLineWidth * currentPDFScaleFactor * 2.4)
                overlayLayer.shadowOffset = .zero
            } else {
                overlayLayer.strokeColor = penColor.cgColor
                overlayLayer.shadowOpacity = 0
                overlayLayer.shadowRadius = 0
            }
            // FileManager처럼 입력 중에는 누적 경로를 그대로 표시합니다. 전체 경로 스무딩은
            // 획 종료 시 한 번만 수행해 긴 획에서 프레임마다 O(n) 재계산하지 않습니다.
            overlayLayer.path = activePenOverlayPath.cgPath
            CATransaction.commit()
        }

        /// Apple Pencil 압력값을 하나의 연속 외곽선으로 변환해 드래그 중인 화면 Overlay에 즉시 표시합니다.
        func refreshPressurePenOverlay() {
            guard let pdfView,
                  !activePenViewPoints.isEmpty,
                  activePenViewPoints.count == activePenPressures.count else { return }

            let overlayLayer = activePressureOverlayLayer ?? makePressurePenOverlayLayer()
            // 긴 압력선도 화면 표시 샘플 수를 제한해 프레임 계산량을 일정하게 유지합니다.
            // 원본 전 좌표는 그대로 보관하며 획 종료 시 한 번만 전체 정밀 경로로 저장합니다.
            let displaySampleLimit = 240
            let sampleIndices: [Int]
            if activePenViewPoints.count <= displaySampleLimit {
                sampleIndices = Array(activePenViewPoints.indices)
            } else {
                let step = Double(activePenViewPoints.count - 1) / Double(displaySampleLimit - 1)
                sampleIndices = (0..<displaySampleLimit).map { index in
                    min(activePenViewPoints.count - 1, Int((Double(index) * step).rounded()))
                }
            }
            let displayPoints = sampleIndices.map { activePenViewPoints[$0] }
            let displayPressures = sampleIndices.map { activePenPressures[$0] }
            let stabilizedViewPoints = penStrokeSmoothingStrength > 0
                ? displayPoints.terminalFlickStabilized(strength: penStrokeSmoothingStrength)
                : displayPoints
            let path = PortalPDFPressureInkAnnotation.makeStrokePath(
                points: stabilizedViewPoints,
                pressures: displayPressures,
                baseLineWidth: penLineWidth * currentPDFScaleFactor
            )

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlayLayer.frame = pdfView.bounds
            overlayLayer.fillColor = penColor.cgColor
            overlayLayer.path = path?.cgPath
            overlayLayer.isHidden = false
            CATransaction.commit()
        }

        /// 현재 지우개가 적용되는 화면 좌표 기준 범위를 원형으로 표시합니다.
        func updateEraserOverlay(at viewPoint: CGPoint) {
            guard let pdfView else { return }
            let radius = eraserSize
            let overlayLayer = activeEraserOverlayLayer ?? makeEraserOverlayLayer()
            let circleRect = CGRect(
                x: viewPoint.x - radius,
                y: viewPoint.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlayLayer.frame = pdfView.bounds
            overlayLayer.path = UIBezierPath(ovalIn: circleRect).cgPath
            overlayLayer.isHidden = false
            CATransaction.commit()
        }

        /// 지우개 범위 원형 가이드를 생성합니다.
        func makeEraserOverlayLayer() -> CAShapeLayer {
            let overlayLayer = CAShapeLayer()
            overlayLayer.fillColor = UIColor.clear.cgColor
            overlayLayer.strokeColor = UIColor.systemRed.withAlphaComponent(0.82).cgColor
            overlayLayer.lineWidth = 1.5
            overlayLayer.lineDashPattern = [5, 3]
            overlayLayer.contentsScale = UIScreen.main.scale
            overlayLayer.zPosition = 20
            pdfView?.layer.addSublayer(overlayLayer)
            activeEraserOverlayLayer = overlayLayer
            return overlayLayer
        }

        /// 지우개 범위 원형 가이드를 숨깁니다.
        func hideEraserOverlay() {
            activeEraserOverlayLayer?.isHidden = true
        }

        /**
         펜 실시간 표시용 Shape Layer를 생성하고 PDFView 최상단 Layer로 연결합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Returns: 펜 실시간 표시용 CAShapeLayer 입니다.
         */
        func makePenOverlayLayer() -> CAShapeLayer {
            let overlayLayer = CAShapeLayer()
            overlayLayer.fillColor = UIColor.clear.cgColor
            overlayLayer.strokeColor = penColor.cgColor
            overlayLayer.lineWidth = penLineWidth * currentPDFScaleFactor
            overlayLayer.lineCap = .round
            overlayLayer.lineJoin = .round
            overlayLayer.contentsScale = UIScreen.main.scale
            overlayLayer.allowsEdgeAntialiasing = true
            overlayLayer.rasterizationScale = UIScreen.main.scale
            if selectedTool == .neon {
                overlayLayer.strokeColor = neonCoreColor(for: penColor).cgColor
                overlayLayer.shadowColor = penColor.cgColor
                overlayLayer.shadowOpacity = 1
                overlayLayer.shadowRadius = max(5, penLineWidth * currentPDFScaleFactor * 2.4)
                overlayLayer.shadowOffset = .zero
            }
            pdfView?.layer.addSublayer(overlayLayer)
            activePenOverlayLayer = overlayLayer
            return overlayLayer
        }

        /// 압력 반응 펜의 전체 획 외곽선을 표시할 실시간 Shape Layer를 생성합니다.
        func makePressurePenOverlayLayer() -> CAShapeLayer {
            let overlayLayer = CAShapeLayer()
            overlayLayer.fillColor = penColor.cgColor
            overlayLayer.fillRule = .nonZero
            overlayLayer.strokeColor = UIColor.clear.cgColor
            overlayLayer.contentsScale = UIScreen.main.scale
            overlayLayer.allowsEdgeAntialiasing = true
            overlayLayer.rasterizationScale = UIScreen.main.scale
            pdfView?.layer.addSublayer(overlayLayer)
            activePressureOverlayLayer = overlayLayer
            return overlayLayer
        }

        /// 현재 획을 PDF 파일과 분리된 페이지 오버레이 네온 라인으로 확정합니다.
        func addTransientNeonStroke(to page: PDFPage) {
            guard let pdfView, !activePenPagePoints.isEmpty else { return }
            var points = activePenPagePoints
            if points.count == 1, let point = points.first {
                points.append(CGPoint(x: point.x + max(0.01, penLineWidth * 0.02), y: point.y))
            }
            let stroke = TransientNeonStroke(
                page: page,
                pagePoints: points,
                color: penColor,
                lineWidth: penLineWidth
            )
            transientNeonStrokes.append(stroke)
            if let overlay = pageOverlayViews[ObjectIdentifier(page)] {
                renderTransientNeonStrokes(on: page, in: overlay, pdfView: pdfView)
            }
        }

        /// 페이지 좌표에 저장한 모든 네온 획을 현재 페이지 오버레이 좌표로 다시 그립니다.
        func renderTransientNeonStrokes(on page: PDFPage, in overlay: UIView, pdfView: PDFView) {
            let pageStrokes = transientNeonStrokes.filter { $0.page === page }
            guard !pageStrokes.isEmpty else { return }
            overlay.layoutIfNeeded()

            pageStrokes.forEach { stroke in
                stroke.layers.forEach { $0.removeFromSuperlayer() }
                stroke.layers = []
                let viewPoints = stroke.pagePoints.map { point in
                    overlay.convert(pdfView.convert(point, from: page), from: pdfView)
                }
                guard let firstPoint = viewPoints.first else { return }
                let path = makeRoundedPath(startPoint: firstPoint)
                viewPoints.dropFirst().forEach { path.addLine(to: $0) }
                let smoothedPath = path.smoothedForPDFInk()

                let origin = overlay.convert(pdfView.convert(CGPoint.zero, from: page), from: pdfView)
                let unitX = overlay.convert(pdfView.convert(CGPoint(x: 1, y: 0), from: page), from: pdfView)
                let pageUnitScale = max(0.1, hypot(unitX.x - origin.x, unitX.y - origin.y))
                let coreWidth = max(0.5, stroke.lineWidth * pageUnitScale)

                let outerGlow = makeNeonLayer(
                    path: smoothedPath,
                    color: stroke.color.withAlphaComponent(0.24),
                    lineWidth: coreWidth * 5.2,
                    in: overlay
                )
                outerGlow.shadowColor = stroke.color.cgColor
                outerGlow.shadowOpacity = 1
                outerGlow.shadowRadius = max(6, coreWidth * 2.8)
                outerGlow.shadowOffset = .zero

                let innerGlow = makeNeonLayer(
                    path: smoothedPath,
                    color: stroke.color.withAlphaComponent(0.64),
                    lineWidth: coreWidth * 2.6,
                    in: overlay
                )
                let core = makeNeonLayer(
                    path: smoothedPath,
                    color: neonCoreColor(for: stroke.color),
                    lineWidth: coreWidth,
                    in: overlay
                )
                stroke.layers = [outerGlow, innerGlow, core]
            }
        }

        /// 발광 한 겹을 구성하는 둥근 Shape Layer를 페이지 오버레이에 추가합니다.
        func makeNeonLayer(path: UIBezierPath, color: UIColor, lineWidth: CGFloat, in overlay: UIView) -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.frame = overlay.bounds
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = color.cgColor
            layer.lineWidth = lineWidth
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.path = path.cgPath
            layer.contentsScale = UIScreen.main.scale
            layer.allowsEdgeAntialiasing = true
            layer.zPosition = 80
            overlay.layer.addSublayer(layer)
            return layer
        }

        /// 선택 색상을 흰색과 섞어 네온 튜브 중심처럼 밝은 코어 색상을 만듭니다.
        func neonCoreColor(for color: UIColor) -> UIColor {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return color }
            let whiteMix: CGFloat = 0.72
            return UIColor(
                red: red * (1 - whiteMix) + whiteMix,
                green: green * (1 - whiteMix) + whiteMix,
                blue: blue * (1 - whiteMix) + whiteMix,
                alpha: max(0.82, alpha)
            )
        }

        /// 마지막 네온 입력 종료 시점을 기준으로 10초 뒤 모든 임시 네온 획을 제거합니다.
        func scheduleTransientNeonClear() {
            neonClearWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.clearTransientNeonStrokes()
            }
            neonClearWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
        }

        /// 문서의 임시 네온 라인을 한꺼번에 제거합니다.
        func clearTransientNeonStrokes() {
            neonClearWorkItem?.cancel()
            neonClearWorkItem = nil
            transientNeonStrokes.forEach { stroke in
                stroke.layers.forEach { $0.removeFromSuperlayer() }
                stroke.layers = []
            }
            transientNeonStrokes = []
        }

        /// PDF Page 기준 굵기를 PDFView 화면 표시 굵기로 변환하기 위한 현재 확대 배율입니다.
        var currentPDFScaleFactor: CGFloat {
            max(pdfView?.scaleFactor ?? 1.0, 0.1)
        }

        /// 압력값 변화가 반영된 자유선을 하나의 연속 Annotation으로 저장합니다.
        func addPressureInkAnnotations(to page: PDFPage) -> PDFAnnotation? {
            let stabilizedViewPoints = penStrokeSmoothingStrength > 0
                ? activePenViewPoints.terminalFlickStabilized(strength: penStrokeSmoothingStrength)
                : activePenViewPoints
            let stabilizedPagePoints = penStrokeSmoothingStrength > 0
                ? activePenPagePoints.terminalFlickStabilized(strength: penStrokeSmoothingStrength)
                : activePenPagePoints
            guard activePenPagePoints.count > 1,
                  activePenPagePoints.count == activePenPressures.count,
                  activePenViewPoints.count == activePenPressures.count,
                  let pdfView,
                  let viewPath = PortalPDFPressureInkAnnotation.makeStrokePath(
                    points: stabilizedViewPoints,
                    pressures: activePenPressures,
                    baseLineWidth: penLineWidth * currentPDFScaleFactor
                  ) else { return nil }
            // 실시간 Overlay에 표시한 최종 외곽선을 그대로 Page 좌표로 옮겨 저장합니다.
            // 종료 시 좌표를 단순화해 다시 그리지 않으므로 Pencil을 떼는 순간 획이 튀거나
            // 작은 곡선이 각진 선으로 바뀌지 않습니다.
            let renderedPagePath = UIBezierPath(cgPath: viewPath.cgPath)
            renderedPagePath.apply(viewToPageTransform(for: page, in: pdfView))
            let annotation = PortalPDFPressureInkAnnotation(
                points: stabilizedPagePoints,
                pressures: activePenPressures,
                baseLineWidth: penLineWidth,
                color: penColor,
                renderedPath: renderedPagePath
            )
            page.addAnnotation(annotation)
            PortalPDFInkDisplaySuppression.suppress(on: page)
            return annotation
        }

        /// PDFView 좌표를 현재 Page 좌표로 변환하는 Affine Transform을 계산합니다.
        func viewToPageTransform(for page: PDFPage, in pdfView: PDFView) -> CGAffineTransform {
            let origin = pdfView.convert(CGPoint.zero, to: page)
            let xAxis = pdfView.convert(CGPoint(x: 1, y: 0), to: page)
            let yAxis = pdfView.convert(CGPoint(x: 0, y: 1), to: page)
            return CGAffineTransform(
                a: xAxis.x - origin.x,
                b: xAxis.y - origin.y,
                c: yAxis.x - origin.x,
                d: yAxis.y - origin.y,
                tx: origin.x,
                ty: origin.y
            )
        }

        /**
         PDF Page에 자유선 Ink Annotation을 최종 추가합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - path: PDF Page 좌표계 기준 자유선 경로입니다.
            - page: 주석을 추가할 PDF Page 입니다.
         */
        func addInkAnnotation(
            path: UIBezierPath,
            to page: PDFPage,
            lineWidth: CGFloat? = nil,
            isPathSmoothed: Bool = false
        ) -> PDFAnnotation? {
            let smoothedPath = isPathSmoothed
                ? path
                : path.smoothedForPDFInk(
                    strokeSmoothingStrength: selectedTool == .pen ? penStrokeSmoothingStrength : 0
                )
            let lineCapStyle = selectedTool == .highlighter ? highlighterCap.lineCapStyle : CGLineCap.round
            smoothedPath.lineCapStyle = lineCapStyle
            smoothedPath.lineJoinStyle = .round
            let annotationBounds = smoothedPath.bounds.insetBy(dx: -10, dy: -10)
            guard annotationBounds.width > 1 || annotationBounds.height > 1 else { return nil }
            let localPath = smoothedPath.translatedBy(dx: -annotationBounds.minX, dy: -annotationBounds.minY)
            localPath.lineCapStyle = lineCapStyle
            localPath.lineJoinStyle = .round
            let annotation = PDFAnnotation(bounds: annotationBounds, forType: .ink, withProperties: nil)
            annotation.color = penColor
            annotation.shouldDisplay = true
            annotation.shouldPrint = true
            let border = PDFBorder()
            border.lineWidth = max(0.3, lineWidth ?? penLineWidth)
            annotation.border = border
            annotation.add(localPath)
            page.addAnnotation(annotation)
            // 화면에서는 PDFKit Annotation 레이어를 만들지 않고 현재 페이지 타일만 갱신합니다.
            // 저장 시 최대 128개 경로 단위로 합치므로 긴 필기 세션의 파일 객체 수도 제한됩니다.
            PortalPDFInkDisplaySuppression.suppress(on: page)
            return annotation
        }

        /**
         박스 드래그 중 PDFView 위에 올린 Shape Layer 경로를 갱신합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - endPoint: PDFView 좌표계 기준 현재 드래그 지점입니다.
         */
        func refreshActiveBoxOverlay(to endPoint: CGPoint) {
            guard let startPoint = activeBoxStartViewPoint else { return }
            let rect = CGRect(
                x: min(startPoint.x, endPoint.x),
                y: min(startPoint.y, endPoint.y),
                width: abs(startPoint.x - endPoint.x),
                height: abs(startPoint.y - endPoint.y)
            )
            let overlayLayer = activeBoxOverlayLayer ?? makeBoxOverlayLayer()
            overlayLayer.frame = pdfView?.bounds ?? .zero
            overlayLayer.lineWidth = DrawingMetrics.boxPDFLineWidth * currentPDFScaleFactor
            overlayLayer.path = PortalPDFShapePath.make(
                selectedShapeType,
                in: rect,
                yAxisPointsDown: true
            ).cgPath
        }

        /**
         박스 실시간 표시용 Shape Layer를 생성하고 PDFView 최상단 Layer로 연결합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Returns: 박스 실시간 표시용 CAShapeLayer 입니다.
         */
        func makeBoxOverlayLayer() -> CAShapeLayer {
            let overlayLayer = CAShapeLayer()
            overlayLayer.fillColor = UIColor.clear.cgColor
            overlayLayer.strokeColor = UIColor.systemOrange.cgColor
            overlayLayer.lineWidth = DrawingMetrics.boxPDFLineWidth * currentPDFScaleFactor
            overlayLayer.lineCap = .round
            overlayLayer.lineJoin = .round
            overlayLayer.contentsScale = UIScreen.main.scale
            pdfView?.layer.addSublayer(overlayLayer)
            activeBoxOverlayLayer = overlayLayer
            return overlayLayer
        }

        /**
         PDF Page에 선택한 도형 Annotation을 최종 추가합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - startPoint: 드래그 시작 PDF Page 좌표입니다.
            - endPoint: 드래그 종료 PDF Page 좌표입니다.
            - page: 주석을 추가할 PDF Page 입니다.
         */
        func addBoxAnnotation(from startPoint: CGPoint, to endPoint: CGPoint, on page: PDFPage) {
            let rect = CGRect(
                x: min(startPoint.x, endPoint.x),
                y: min(startPoint.y, endPoint.y),
                width: abs(startPoint.x - endPoint.x),
                height: abs(startPoint.y - endPoint.y)
            )
            guard rect.width > 8, rect.height > 8 else { return }
            let annotation = PortalPDFShapeAnnotation(
                shapeType: selectedShapeType,
                bounds: rect,
                lineWidth: DrawingMetrics.boxPDFLineWidth,
                lineColor: shapeLineColor,
                fillColor: shapeFillColor
            )
            page.addAnnotation(annotation)
            // Page에 연결된 뒤에는 회전·선택 UI까지 포함한 외곽 영역이 페이지 안에 남도록 보정합니다.
            annotation.editingBounds = annotation.editingBounds
            // PDFKit은 커스텀 Annotation 추가 직후 기존 document view 캐시를 유지할 수 있어
            // layoutDocumentView()로 페이지 Annotation 레이아웃을 갱신한 뒤 다시 그립니다.
            if let pdfView {
                selectShapeAnnotation(annotation, in: pdfView)
            }
            pdfView?.layoutDocumentView()
            pdfView?.setNeedsDisplay()
            pdfView?.documentView?.setNeedsDisplay()
        }

        /// 선택한 도형을 현재 보고 있는 PDF 페이지 중앙에 추가하고 바로 크기·회전 편집 대상으로 만듭니다.
        @discardableResult
        func addShapeAnnotation(_ shapeType: PortalPDFShapeType, in pdfView: PDFView) -> Bool {
            let viewCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            guard let page = pdfView.page(for: viewCenter, nearest: true) ?? pdfView.currentPage else { return false }
            let pageCenter = pdfView.convert(viewCenter, to: page)
            let pageBounds = page.bounds(for: .cropBox)
            let defaultSize = CGSize(
                width: min(pageBounds.width * 0.34, 176),
                height: min(pageBounds.height * 0.18, 112)
            )
            let contentBounds = CGRect(
                x: pageCenter.x - defaultSize.width / 2,
                y: pageCenter.y - defaultSize.height / 2,
                width: defaultSize.width,
                height: defaultSize.height
            )
            guard contentBounds.width > 8, contentBounds.height > 8 else { return false }

            let annotation = PortalPDFShapeAnnotation(
                shapeType: shapeType,
                bounds: contentBounds,
                lineWidth: DrawingMetrics.boxPDFLineWidth,
                lineColor: shapeLineColor,
                fillColor: shapeFillColor
            )
            page.addAnnotation(annotation)
            annotation.editingBounds = annotation.editingBounds
            selectShapeAnnotation(annotation, in: pdfView)
            pdfView.layoutDocumentView()
            pdfView.setNeedsDisplay()
            pdfView.documentView?.setNeedsDisplay()
            return true
        }

        /**
         현재 PDFView에서 보고 있는 페이지 중앙에 이미지 주석을 추가합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - image: PDF 페이지에 표시할 이미지입니다.
            - pdfView: 현재 표시 중인 PDFView 입니다.
         */
        @discardableResult
        func addImageAnnotation(
            _ image: UIImage,
            animatedGIFData: Data? = nil,
            in pdfView: PDFView
        ) -> Bool {
            let viewCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            guard let page = pdfView.page(for: viewCenter, nearest: true) ?? pdfView.currentPage else { return false }
            let pageCenter = pdfView.convert(viewCenter, to: page)
            let pageBounds = page.bounds(for: .cropBox)
            let annotationBounds = PortalPDFImageInsertionLayout.bounds(
                imageSize: image.size,
                viewportSize: pdfView.bounds.size,
                scaleFactor: pdfView.scaleFactor,
                pageBounds: pageBounds,
                center: pageCenter
            )
            guard annotationBounds.width > 8, annotationBounds.height > 8 else { return false }
            let persistedImageData = image.jpegData(compressionQuality: 0.84)
                ?? image.pngData()
                ?? Data()
            let annotation = PortalPDFImageAnnotation(
                image: image,
                persistedImageData: persistedImageData,
                bounds: annotationBounds,
                animatedGIFData: animatedGIFData
            )
            page.addAnnotation(annotation)
            // 이미지·점선 선택 영역·오른쪽 조절 버튼까지 페이지 밖으로 잘리지 않도록 보정합니다.
            annotation.editingBounds = annotation.editingBounds
            selectImageAnnotation(annotation, in: pdfView)
            prewarmCurrentPDFAnnotationRendering(in: pdfView)
            return true
        }

        /// 새 이미지가 들어간 직후 PDFKit 렌더 캐시를 미리 갱신해 첫 드래그가 그 비용을 부담하지 않게 합니다.
        func prewarmCurrentPDFAnnotationRendering(in pdfView: PDFView) {
            pdfView.layoutDocumentView()
            pdfView.layoutIfNeeded()
            pdfView.documentView?.layoutIfNeeded()
            pdfView.setNeedsDisplay()
            pdfView.documentView?.setNeedsDisplay()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfView.layer.displayIfNeeded()
            pdfView.documentView?.layer.displayIfNeeded()
            CATransaction.commit()
        }

        /// 선택 이미지의 위치·크기·회전·반전 상태를 유지한 채 사진 내용만 교체합니다.
        func replaceImageAnnotation(
            _ annotation: PortalPDFImageAnnotation,
            with image: UIImage,
            horizontalFlip: Bool? = nil,
            editingBounds: CGRect? = nil,
            preservesAnimation: Bool = false,
            on page: PDFPage,
            in pdfView: PDFView
        ) {
            let annotationsInDisplayOrder = page.annotations
            let imageData = image.jpegData(compressionQuality: 0.84) ?? image.pngData() ?? Data()
            let replacement = PortalPDFImageAnnotation(
                image: image,
                persistedImageData: imageData,
                bounds: editingBounds ?? annotation.editingBounds,
                animatedGIFData: preservesAnimation ? annotation.animatedGIFData : nil
            )
            replacement.rotationAngle = annotation.rotationAngle
            replacement.isHorizontallyFlipped = horizontalFlip ?? annotation.isHorizontallyFlipped
            annotation.isPortalSelected = false
            annotation.shouldDisplay = false
            annotation.shouldPrint = false
            annotationsInDisplayOrder.forEach { page.removeAnnotation($0) }
            annotationsInDisplayOrder.forEach { existingAnnotation in
                page.addAnnotation(existingAnnotation === annotation ? replacement : existingAnnotation)
            }
            replacement.editingBounds = replacement.editingBounds
            selectImageAnnotation(replacement, in: pdfView, presentsActionMenu: false)
            prewarmCurrentPDFAnnotationRendering(in: pdfView)
        }

        /// 자른 이미지 비율에 맞는 표시 영역을 만들고 원본 유지 설정에 따라 교체 또는 추가합니다.
        func applyCroppedImageAnnotation(
            _ annotation: PortalPDFImageAnnotation,
            with croppedImage: UIImage,
            keepsOriginal: Bool,
            on page: PDFPage,
            in pdfView: PDFView
        ) {
            var croppedBounds = aspectFittedImageBounds(
                imageSize: croppedImage.size,
                inside: annotation.editingBounds
            )
            guard croppedBounds.width >= PortalPDFImageAnnotation.minimumContentSide,
                  croppedBounds.height >= PortalPDFImageAnnotation.minimumContentSide else { return }

            if keepsOriginal {
                // 새 이미지가 원본을 완전히 덮지 않도록 화면상 약간 이동해 두 결과를 함께 확인할 수 있게 합니다.
                let displayScale = max(pdfView.scaleFactor, 0.1)
                let offset = 18 / displayScale
                croppedBounds = croppedBounds
                    .offsetBy(dx: offset, dy: -offset)
                    .clampedInside(page.bounds(for: .cropBox))
                let croppedAnnotation = PortalPDFImageAnnotation(image: croppedImage, bounds: croppedBounds)
                croppedAnnotation.rotationAngle = annotation.rotationAngle
                croppedAnnotation.isHorizontallyFlipped = annotation.isHorizontallyFlipped
                page.addAnnotation(croppedAnnotation)
                croppedAnnotation.editingBounds = croppedAnnotation.editingBounds
                selectImageAnnotation(croppedAnnotation, in: pdfView, presentsActionMenu: false)
                prewarmCurrentPDFAnnotationRendering(in: pdfView)
                return
            }

            replaceImageAnnotation(
                annotation,
                with: croppedImage,
                editingBounds: croppedBounds,
                on: page,
                in: pdfView
            )
        }

        /// 자른 이미지의 종횡비를 유지하면서 이전 표시 영역 안에 들어오는 최대 크기를 계산합니다.
        func aspectFittedImageBounds(imageSize: CGSize, inside container: CGRect) -> CGRect {
            guard imageSize.width > 0,
                  imageSize.height > 0,
                  container.width > 0,
                  container.height > 0 else { return container }
            let imageAspectRatio = imageSize.width / imageSize.height
            let containerAspectRatio = container.width / container.height
            let fittedSize: CGSize
            if imageAspectRatio >= containerAspectRatio {
                fittedSize = CGSize(
                    width: container.width,
                    height: container.width / imageAspectRatio
                )
            } else {
                fittedSize = CGSize(
                    width: container.height * imageAspectRatio,
                    height: container.height
                )
            }
            return CGRect(
                x: container.midX - fittedSize.width / 2,
                y: container.midY - fittedSize.height / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
        }

        /// 이미지 선택 여부가 실제로 변경될 때만 SwiftUI 이미지 작업 패널에 알립니다.
        func reportImageSelection(_ isSelected: Bool) {
            guard lastReportedImageSelectionState != isSelected else { return }
            lastReportedImageSelectionState = isSelected
            onImageSelectionChanged(isSelected)
        }

        /// 도형 선택 여부가 실제로 변경될 때만 SwiftUI 도형 상태에 알립니다.
        func reportShapeSelection(_ isSelected: Bool) {
            guard lastReportedShapeSelectionState != isSelected else { return }
            lastReportedShapeSelectionState = isSelected
            onShapeSelectionChanged(isSelected)
        }

        /**
         PDF Page 좌표에 포함되는 이미지 Annotation을 최신 추가 순서 기준으로 찾습니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - page: 이미지 주석을 찾을 PDF Page 입니다.
            - point: PDF Page 좌표계 기준 선택 위치입니다.
         - Returns: 선택 위치에 있는 이미지 Annotation 입니다.
         */
        func editableAnnotation(on page: PDFPage, point: CGPoint) -> PDFAnnotation? {
            PortalPDFEditableAnnotationHitTesting.topmostAnnotation(
                in: page.annotations,
                at: point,
                scaleFactor: currentPDFScaleFactor
            )
        }

        /**
         이미지 Annotation 하나를 선택 상태로 변경하고 기존 선택 이미지는 해제합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - annotation: 선택할 이미지 Annotation 입니다.
            - pdfView: 선택 UI를 다시 그릴 PDFView 입니다.
         */
        func selectImageAnnotation(
            _ annotation: PortalPDFImageAnnotation,
            in pdfView: PDFView,
            presentsActionMenu: Bool = true
        ) {
            clearSelectedShapeAnnotation()
            annotation.updateEditingDisplayScaleFactor(currentPDFScaleFactor)

            // 이전 이미지 해제와 새 이미지 선택을 한 번의 레이어 갱신으로 처리합니다.
            // 중간에 선택 상태를 false→true로 연속 전달하면 이전 편집 패널과 새 패널이
            // 겹쳐 보이거나 PDFKit 타일 캐시에 이전 핸들이 남을 수 있습니다.
            var affectedAnnotations: [(PDFPage, PDFAnnotation)] = []
            if let document = pdfView.document {
                for pageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: pageIndex) else { continue }
                    page.annotations
                        .compactMap { $0 as? PortalPDFImageAnnotation }
                        .forEach { imageAnnotation in
                            let shouldSelect = imageAnnotation === annotation
                            if imageAnnotation.isPortalSelected != shouldSelect {
                                affectedAnnotations.append((page, imageAnnotation))
                            }
                            imageAnnotation.isPortalSelected = shouldSelect
                        }
                }
            } else {
                annotation.isPortalSelected = true
            }

            activeImageDragState = nil
            selectedImageAnnotation = annotation
            reportImageSelection(true)
            refreshPortalAnnotationTiles(affectedAnnotations, in: pdfView)
            if presentsActionMenu {
                presentImageActionMenu(for: annotation, in: pdfView)
            }
        }

        /// 이미지 편집 모드에서 현재 선택 이미지 이외의 편집 표시를 모두 해제합니다.
        func retainOnlySelectedImageAnnotation(in pdfView: PDFView) {
            guard let document = pdfView.document else {
                selectedImageAnnotation?.isPortalSelected = false
                selectedImageAnnotation = nil
                activeImageDragState = nil
                reportImageSelection(false)
                return
            }

            let selectedAnnotation = selectedImageAnnotation
            var hasSelectedAnnotation = false
            var affectedAnnotations: [(PDFPage, PDFAnnotation)] = []
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                page.annotations
                    .compactMap { $0 as? PortalPDFImageAnnotation }
                    .forEach { annotation in
                        let shouldShowEditingControls = annotation === selectedAnnotation
                        if annotation.isPortalSelected != shouldShowEditingControls {
                            affectedAnnotations.append((page, annotation))
                        }
                        annotation.isPortalSelected = shouldShowEditingControls
                        hasSelectedAnnotation = hasSelectedAnnotation || shouldShowEditingControls
                    }
            }
            if !hasSelectedAnnotation {
                selectedImageAnnotation = nil
                activeImageDragState = nil
            }
            reportImageSelection(hasSelectedAnnotation)
            if affectedAnnotations.isEmpty {
                pdfView.setNeedsDisplay()
                pdfView.documentView?.setNeedsDisplay()
            } else {
                refreshPortalAnnotationTiles(affectedAnnotations, in: pdfView)
            }
        }

        /**
         선택된 이미지 Annotation의 점선 선택 표시를 해제합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         */
        func clearSelectedImageAnnotation() {
            guard let pdfView else {
                selectedImageAnnotation?.isPortalSelected = false
                selectedImageAnnotation = nil
                activeImageDragState = nil
                reportImageSelection(false)
                return
            }
            deactivateAllImageEditing(in: pdfView, forceRedraw: true)
        }

        /// 이미지 편집 모드를 벗어날 때 선택 대상과 문서 전체의 이미지 편집 표시를 확실히 해제합니다.
        ///
        /// PDFKit은 커스텀 Annotation의 내부 프로퍼티만 바뀐 경우 기존 타일을 재사용할 수 있습니다.
        /// 따라서 선택 상태를 해제한 뒤 해당 Portal 주석을 제거·재등록하여 이전 이미지의
        /// 점선, 삭제 버튼, 확대·회전 핸들이 다른 편집 도구에서 남지 않게 합니다.
        func deactivateAllImageEditing(in pdfView: PDFView, forceRedraw: Bool) {
            dismissImageActionMenu()
            guard let document = pdfView.document else {
                selectedImageAnnotation?.isPortalSelected = false
                selectedImageAnnotation = nil
                activeImageDragState = nil
                reportImageSelection(false)
                return
            }

            var affectedAnnotations: [(PDFPage, PDFAnnotation)] = []
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                page.annotations
                    .compactMap { $0 as? PortalPDFImageAnnotation }
                    .forEach { annotation in
                        if annotation.isPortalSelected {
                            affectedAnnotations.append((page, annotation))
                        }
                        annotation.isPortalSelected = false
                    }
            }
            selectedImageAnnotation = nil
            activeImageDragState = nil
            reportImageSelection(false)

            guard forceRedraw, !affectedAnnotations.isEmpty else {
                pdfView.setNeedsDisplay()
                pdfView.documentView?.setNeedsDisplay()
                return
            }
            refreshPortalAnnotationTiles(affectedAnnotations, in: pdfView)
        }

        /// Portal Annotation의 선택 상태 변경을 PDF 레이어에 반영합니다.
        func refreshPortalAnnotationTiles(
            _ annotations: [(PDFPage, PDFAnnotation)],
            in pdfView: PDFView
        ) {
            guard !annotations.isEmpty else { return }
            // PDFKit은 커스텀 Annotation의 선택 플래그만 바꾼 경우 기존 타일을 재사용할 수
            // 있습니다. 영향을 받은 페이지의 Annotation을 기존 순서 그대로 다시 등록해
            // 이전 이미지의 점선·삭제·변형 핸들이 남지 않도록 타일을 확실히 무효화합니다.
            var refreshedPages: [PDFPage] = []
            for (page, _) in annotations {
                guard !refreshedPages.contains(where: { $0 === page }) else { continue }
                let orderedAnnotations = page.annotations
                orderedAnnotations.forEach { page.removeAnnotation($0) }
                orderedAnnotations.forEach { page.addAnnotation($0) }
                refreshedPages.append(page)
            }
            refreshedPages.forEach(refreshPersistentAnnotationOverlay(on:))
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
        }

        /// 주석 변경을 현재 PDF 레이어에만 반영합니다.
        ///
        /// PDFDocument를 `nil`로 분리했다가 다시 연결하면 PDFKit이 내부 문서 뷰와
        /// 스크롤 제스처를 새로 만듭니다. 그 과정에서 화면이 깜빡이고, SwiftUI 입력값이
        /// 바뀌지 않았다는 이유로 지우개 팬 설정이 재적용되지 않아 한 손가락 지우개가
        /// PDF 기본 스크롤 팬에 막힐 수 있습니다. 문서와 PDFView 계층을 유지한 채
        /// annotation 레이어만 무효화하면 두 문제를 함께 피할 수 있습니다.
        func refreshPDFViewAfterAnnotationMutation(in pdfView: PDFView) {
            refreshPersistentInkOverlays()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfView.setNeedsDisplay()
            pdfView.documentView?.setNeedsDisplay()
            pdfView.documentView?.subviews.forEach { $0.setNeedsDisplay() }
            CATransaction.commit()
        }

        /// 지우개 드래그 중에는 현재 PDFView와 문서 컨테이너만 갱신합니다.
        /// 모든 페이지 타일 순회는 손을 뗀 시점에 한 번만 실행해 지우개 원 이동을 막지 않습니다.
        func refreshPDFViewDuringEraser(in pdfView: PDFView, dirtyViewRects: [CGRect]) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let validRects = dirtyViewRects.filter { !$0.isNull && !$0.isEmpty }
            if validRects.isEmpty {
                pdfView.setNeedsDisplay()
            } else {
                validRects.forEach { viewRect in
                    pdfView.setNeedsDisplay(viewRect)
                    if let documentView = pdfView.documentView {
                        documentView.setNeedsDisplay(documentView.convert(viewRect, from: pdfView))
                    }
                }
            }
            CATransaction.commit()
        }

        /// 선택된 이미지 Annotation을 현재 PDF 페이지에서 제거하고 편집 상태를 정리합니다.
        func deleteImageAnnotation(_ annotation: PortalPDFImageAnnotation, from page: PDFPage, in pdfView: PDFView) {
            guard annotation.page === page else { return }
            // 삭제 전에 모든 이미지 편집 표시를 해제하고, 삭제 대상은 페이지 Annotation
            // 컬렉션에서도 반드시 제거합니다. 선택선만 해제되는 경로를 만들지 않습니다.
            deactivateAllImageEditing(in: pdfView, forceRedraw: false)
            activeImageDragState = nil
            annotation.shouldDisplay = false
            annotation.shouldPrint = false
            page.removeAnnotation(annotation)
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
            onDocumentChanged()
        }

        /// 도형 Annotation 하나를 선택 상태로 변경하고 기존 편집 대상을 해제합니다.
        func selectShapeAnnotation(_ annotation: PortalPDFShapeAnnotation, in pdfView: PDFView) {
            clearSelectedImageAnnotation()
            // 기존 도형의 선택 상태를 먼저 끄고 새 도형만 활성화합니다.
            // 재갱신은 새 선택까지 반영한 뒤 한 번만 수행해 ON/OFF 표시가 즉시 맞도록 합니다.
            clearSelectedShapeAnnotation(forceRedraw: false)
            annotation.isPortalSelected = true
            annotation.updateEditingDisplayScaleFactor(currentPDFScaleFactor)
            selectedShapeAnnotation = annotation
            reportShapeSelection(true)
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
        }

        /// 선택된 도형 Annotation의 점선 선택 표시를 해제합니다.
        func clearSelectedShapeAnnotation(forceRedraw: Bool = true) {
            guard let pdfView else {
                selectedShapeAnnotation?.isPortalSelected = false
                selectedShapeAnnotation = nil
                reportShapeSelection(false)
                activeImageDragState = nil
                return
            }

            var hasSelectedShape = false
            if let document = pdfView.document {
                for pageIndex in 0..<document.pageCount {
                    document.page(at: pageIndex)?.annotations
                        .compactMap { $0 as? PortalPDFShapeAnnotation }
                        .forEach {
                            if $0.isPortalSelected {
                                hasSelectedShape = true
                            }
                            $0.isPortalSelected = false
                        }
                }
            } else {
                hasSelectedShape = selectedShapeAnnotation?.isPortalSelected == true
                selectedShapeAnnotation?.isPortalSelected = false
            }
            selectedShapeAnnotation = nil
            reportShapeSelection(false)
            activeImageDragState = nil
            guard forceRedraw, hasSelectedShape else {
                pdfView.setNeedsDisplay()
                pdfView.documentView?.setNeedsDisplay()
                return
            }
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
        }

        /// 선택된 도형을 현재 PDF 페이지에서 제거하고 편집 상태를 정리합니다.
        func deleteShapeAnnotation(_ annotation: PortalPDFShapeAnnotation, from page: PDFPage, in pdfView: PDFView) {
            guard annotation.page === page else { return }
            if selectedShapeAnnotation === annotation {
                clearSelectedShapeAnnotation(forceRedraw: false)
            } else {
                annotation.isPortalSelected = false
            }
            activeImageDragState = nil
            annotation.shouldDisplay = false
            annotation.shouldPrint = false
            page.removeAnnotation(annotation)
            refreshPDFViewAfterAnnotationMutation(in: pdfView)
            onDocumentChanged()
        }

        /**
         이미지 Annotation의 현재 크기를 유지하면서 PDF Page 안에서 위치만 이동합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - annotation: 이동할 이미지 Annotation 입니다.
            - delta: PDF Page 좌표계 기준 이동 거리입니다.
            - page: 이미지 Annotation이 포함된 PDF Page 입니다.
         */
        func moveAnnotation(_ annotation: PortalPDFTransformableAnnotation, by delta: CGPoint, on page: PDFPage) {
            let pageBounds = page.bounds(for: .cropBox)
            let movedBounds = annotation.editingBounds.offsetBy(dx: delta.x, dy: delta.y)
            annotation.editingBounds = annotation.constrainedEditingBounds(movedBounds, in: pageBounds)
            if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                refreshImageAnnotationPresentation(imageAnnotation, on: page)
            } else {
                pdfView?.setNeedsDisplay()
            }
        }

        /**
         이미지 Annotation의 중심을 유지하면서 크기를 변경합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - annotation: 크기를 변경할 이미지 Annotation 입니다.
            - scale: Pinch Gesture에서 전달된 상대 확대/축소 배율입니다.
            - page: 이미지 Annotation이 포함된 PDF Page 입니다.
         */
        func scaleAnnotation(_ annotation: PortalPDFTransformableAnnotation, by scale: CGFloat, on page: PDFPage) {
            let currentBounds = annotation.editingBounds
            let pageBounds = page.bounds(for: .cropBox)
            let center = CGPoint(x: currentBounds.midX, y: currentBounds.midY)
            guard currentBounds.width > 0, currentBounds.height > 0 else { return }
            let requestedScale = scale.isFinite ? max(scale, 0.01) : 1
            // 이미지의 편집용 외곽 영역은 본문과 분리되어 있으므로, 본문 기준 최소 크기만 제한합니다.
            let minSide: CGFloat = annotation is PortalPDFImageAnnotation
                ? PortalPDFImageAnnotation.minimumContentSide
                : 32
            let maxWidth = pageBounds.width * 0.92
            let maxHeight = pageBounds.height * 0.92
            // 폭과 높이를 각각 clamp하면 한쪽이 먼저 최대값에 닿는 순간 이미지가 찌그러집니다.
            // 두 축을 동시에 만족하는 단일 배율 범위를 계산해 항상 원본 비율을 유지합니다.
            let minimumScale = max(
                minSide / currentBounds.width,
                minSide / currentBounds.height
            )
            let maximumScale = min(
                maxWidth / currentBounds.width,
                maxHeight / currentBounds.height
            )
            let clampedScale = min(max(requestedScale, minimumScale), maximumScale)
            let nextWidth = currentBounds.width * clampedScale
            let nextHeight = currentBounds.height * clampedScale
            let nextBounds = CGRect(
                x: center.x - nextWidth / 2,
                y: center.y - nextHeight / 2,
                width: nextWidth,
                height: nextHeight
            )
            annotation.editingBounds = annotation.constrainedEditingBounds(nextBounds, in: pageBounds)
            if !(annotation is PortalPDFImageAnnotation) {
                pdfView?.setNeedsDisplay()
            }
        }

        /**
         PDFView 기본 확대/회전 제스처가 이미지 편집 제스처와 충돌하지 않도록 상태를 조정합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - isViewing: PDF 기본 보기 모드 여부입니다.
            - isEditing: PDF 편집 도구가 선택된 상태인지 여부입니다.
            - pdfView: Gesture Recognizer 상태를 조정할 PDFView 입니다.
         */
        func updatePDFViewTransformGestures(
            isViewing: Bool,
            isEditing: Bool,
            in pdfView: PDFView
        ) {
            prioritizeImageLongPressOverPDFGestures(in: pdfView)
            if !isEditing {
                // 보기 모드로 돌아갈 때 이 화면에서 끈 PDFKit 기본 제스처만 복원합니다.
                editingDisabledDocumentGestures.allObjects.forEach { $0.isEnabled = true }
                editingDisabledDocumentGestures.removeAllObjects()
            }

            let editorGestures: [UIGestureRecognizer?] = [
                imageLongPressGesture,
                penDrawingGesture,
                drawingPanGesture,
                lassoTapGesture,
                eraserDrawingGesture,
                imageTapGesture,
                imageDeleteTapGesture,
                shapeTapGesture,
                textTapGesture,
                textTouchDownGesture,
                textDeleteTapGesture,
                textLongPressGesture,
                imageRotationGesture,
            ]
            let scrollPanGestureIDs = Set(
                pdfView.recursiveScrollViews.map { ObjectIdentifier($0.panGestureRecognizer) }
            )

            pdfView.allGestureRecognizers.forEach { gestureRecognizer in
                if let activeTextEditor,
                   let gestureView = gestureRecognizer.view,
                   gestureView === activeTextEditor || gestureView.isDescendant(of: activeTextEditor) {
                    return
                }
                guard gestureRecognizer !== imageRotationGesture else { return }
                let isEditorGesture = editorGestures.contains { editorGesture in
                    guard let editorGesture else { return false }
                    return editorGesture === gestureRecognizer
                }
                guard !isEditorGesture else { return }

                if let doubleTapGesture = gestureRecognizer as? UITapGestureRecognizer,
                   doubleTapGesture.numberOfTapsRequired == 2 {
                    // 편집 중 더블탭이 원본 배율 복귀나 문구 선택으로 해석되지 않게 합니다.
                    if isEditing, doubleTapGesture.isEnabled {
                        editingDisabledDocumentGestures.add(doubleTapGesture)
                        doubleTapGesture.isEnabled = false
                    }
                } else if let pinchGesture = gestureRecognizer as? UIPinchGestureRecognizer {
                    // 이미지 자체를 바꾸는 커스텀 Pinch는 제거했지만,
                    // PDFView 전체를 확대·축소하는 기본 Pinch는 모든 모드에서 유지합니다.
                    pinchGesture.isEnabled = true
                } else if gestureRecognizer is UIRotationGestureRecognizer {
                    gestureRecognizer.isEnabled = isViewing
                } else if isEditing,
                          gestureRecognizer is UILongPressGestureRecognizer
                            || gestureRecognizer is UITapGestureRecognizer
                            || (gestureRecognizer is UIPanGestureRecognizer
                                && !scrollPanGestureIDs.contains(ObjectIdentifier(gestureRecognizer))) {
                    // PDFKit의 문구 선택, 복사/돋보기 메뉴와 텍스트 범위 드래그는
                    // 모든 편집 모드가 끝날 때까지 중지합니다. ScrollView의 두 손가락
                    // 이동과 Pinch 확대·축소는 이 조건에서 제외합니다.
                    if gestureRecognizer.isEnabled {
                        editingDisabledDocumentGestures.add(gestureRecognizer)
                        gestureRecognizer.isEnabled = false
                    }
                }
            }
        }

        /**
         PDFKit 기본 선택/이동 제스처보다 이미지 주석 롱프레스가 먼저 판정되도록 우선순위를 연결합니다.
         이미지 위가 아닌 곳에서는 롱프레스가 즉시 실패하므로 PDF 기본 동작은 그대로 유지됩니다.
         */
        func prioritizeImageLongPressOverPDFGestures(in pdfView: PDFView) {
            guard let imageLongPressGesture else { return }
            let editorGestures: [UIGestureRecognizer?] = [
                imageLongPressGesture,
                penDrawingGesture,
                drawingPanGesture,
                lassoTapGesture,
                eraserDrawingGesture,
                imageTapGesture,
                imageDeleteTapGesture,
                shapeTapGesture,
                textTapGesture,
                textTouchDownGesture,
                textDeleteTapGesture,
                textLongPressGesture,
                imageRotationGesture,
            ]

            pdfView.allGestureRecognizers.forEach { gestureRecognizer in
                if let activeTextEditor,
                   let gestureView = gestureRecognizer.view,
                   gestureView === activeTextEditor || gestureView.isDescendant(of: activeTextEditor) {
                    return
                }
                let isEditorGesture = editorGestures.contains { editorGesture in
                    guard let editorGesture else { return false }
                    return editorGesture === gestureRecognizer
                }
                guard !isEditorGesture else { return }
                guard gestureRecognizer is UILongPressGestureRecognizer
                        || gestureRecognizer is UITapGestureRecognizer
                        || gestureRecognizer is UIPanGestureRecognizer else { return }
                let identifier = ObjectIdentifier(gestureRecognizer)
                guard prioritizedPDFGestureIDs.insert(identifier).inserted else { return }
                if let imageDeleteTapGesture {
                    gestureRecognizer.require(toFail: imageDeleteTapGesture)
                }
                if let textDeleteTapGesture {
                    gestureRecognizer.require(toFail: textDeleteTapGesture)
                }
                gestureRecognizer.require(toFail: imageLongPressGesture)
            }
        }

        /**
         탭 위치 근처의 주석을 찾아 지우개 선택 범위를 보정합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - page: 주석을 찾을 PDF Page 입니다.
            - point: PDF Page 좌표계 기준 탭 위치입니다.
         - Returns: 삭제 대상에 가장 가까운 주석입니다.
         */
        func nearestAnnotation(on page: PDFPage, point: CGPoint) -> PDFAnnotation? {
            let hitRadius = eraserSize / currentPDFScaleFactor
            return page.annotations.reversed().first { annotation in
                guard isErasableAnnotation(annotation) else { return false }
                if PortalPDFPressureInkAnnotation.isPressureInk(annotation) {
                    return PortalPDFPressureInkAnnotation.containsStroke(
                        in: annotation,
                        point: point,
                        extraRadius: hitRadius
                    )
                }
                return standardInkContainsStroke(
                    annotation,
                    point: point,
                    extraRadius: hitRadius
                )
            }
        }

        /**
         현재 진행 중인 펜/박스 편집 상태와 화면 Overlay Layer를 초기화합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         */
        func resetActiveDrawing(keepingInkOverlayLayers: Bool = false) {
            stopActivePenOverlayRefresh()
            if !keepingInkOverlayLayers {
                activePenOverlayLayer?.removeFromSuperlayer()
                activePressureOverlayLayer?.removeFromSuperlayer()
            }
            activeBoxOverlayLayer?.removeFromSuperlayer()
            activePenPage = nil
            activePenPath = nil
            activePenPagePoints = []
            activePenViewPoints = []
            activePenPressures = []
            activePenOverlayPath = nil
            activePenLastViewPoint = nil
            activePenSampleCount = 0
            activePenPageCurvePoints = [CGPoint](repeating: .zero, count: 4)
            activePenViewCurvePoints = [CGPoint](repeating: .zero, count: 4)
            activePenCurveIndex = 0
            activePenOverlayLayer = nil
            activePressureOverlayLayer = nil
            activeBoxPage = nil
            activeBoxStartPoint = nil
            activeBoxStartViewPoint = nil
            activeBoxOverlayLayer = nil
            activeImageDragState = nil
        }
    }
}

/**
 PDF 첨부 파일 로딩 상태입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalPDFPreviewView``
 */
