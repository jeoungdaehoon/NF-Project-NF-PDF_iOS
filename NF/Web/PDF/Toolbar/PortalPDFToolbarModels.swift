//
// PortalPDFToolbarModels.swift
// NF
//
// Toolbar models, picker adapters, history commands, and tool definitions.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

struct PortalPDFMarkupDragContainer<Content: View>: View {
    /// 드래그 종료 후 상위 화면에 보관할 확정 위치입니다.
    @Binding var committedOffset: CGSize
    /// 드래그 중 상위 화면에 전달할 실시간 위치입니다.
    @Binding var liveOffset: CGSize
    /// 이동 중 손가락을 따라갈 임시 translation입니다.
    @GestureState private var dragTranslation: CGSize = .zero
    /// 이동 제스처가 활성화된 상태인지 나타냅니다.
    @State private var isDragging: Bool = false
    /// 현재 화면 경계 안으로 위치를 제한하는 이벤트입니다.
    let clampOffset: (CGSize) -> CGSize
    /// 이동 없이 클릭만 한 경우 가로·세로 방향을 전환하는 이벤트입니다.
    let onTapMoveButton: () -> Void
    /// 이동 버튼에 전용 제스처를 연결해 표시할 편집 알약 콘텐츠입니다.
    let content: (AnyGesture<DragGesture.Value>) -> Content

    init(
        committedOffset: Binding<CGSize>,
        liveOffset: Binding<CGSize>,
        clampOffset: @escaping (CGSize) -> CGSize,
        onTapMoveButton: @escaping () -> Void,
        @ViewBuilder content: @escaping (AnyGesture<DragGesture.Value>) -> Content
    ) {
        _committedOffset = committedOffset
        _liveOffset = liveOffset
        self.clampOffset = clampOffset
        self.onTapMoveButton = onTapMoveButton
        self.content = content
    }

    var body: some View {
        content(moveGesture)
            // 알약과 상세 편집창을 하나의 합성 레이어로 묶어 이동 중 개별 요소 깜빡임을 줄입니다.
            .compositingGroup()
            // 이동 중에는 전용 하위 뷰만 offset을 갱신해 PDFView 재렌더링을 방지합니다.
            .offset(clampOffset(proposedOffset))
            .transaction { transaction in
                if isDragging || dragTranslation != .zero {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .onAppear {
                liveOffset = committedOffset
            }
    }

    /// 확정 위치와 현재 손가락 이동량을 합산한 실시간 위치입니다.
    var proposedOffset: CGSize {
        CGSize(
            width: committedOffset.width + dragTranslation.width,
            height: committedOffset.height + dragTranslation.height
        )
    }

    /// 대기 시간 없이 이동을 시작하고 종료 시에만 위치를 상위 화면에 확정합니다.
    var moveGesture: AnyGesture<DragGesture.Value> {
        AnyGesture(
            // 이동 대상 뷰의 로컬 좌표를 기준으로 translation을 계산하면 offset 적용 시
            // 좌표 원점도 함께 이동해 위치값이 반복 보정되므로, 움직이지 않는 전역 좌표를 기준으로 계산합니다.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragTranslation) { value, translation, _ in
                translation = value.translation
            }
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                }
                liveOffset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                let isTap = abs(value.translation.width) < 4 && abs(value.translation.height) < 4
                if isTap {
                    onTapMoveButton()
                } else {
                    let finalOffset = CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    )
                    committedOffset = clampOffset(finalOffset)
                }
                liveOffset = committedOffset
                isDragging = false
            }
        )
    }
}

/**
 PDFView에 이미지 주석을 1회 추가하기 위해 전달하는 선택 이미지 모델입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalPDFPreviewView``, ``PortalPDFKitView``
 */
struct PortalPDFPendingImage: Equatable {
    /// 같은 이미지를 연속 선택해도 PDFView가 새 삽입 요청으로 인식하도록 생성 시점마다 부여하는 식별자입니다.
    let id = UUID()
    /// PDF 페이지에 추가할 UIKit 이미지입니다.
    let image: UIImage

    /// SwiftUI 갱신 시 이미지 객체가 아닌 삽입 요청 식별자를 기준으로 동일 여부를 판단합니다.
    static func == (lhs: PortalPDFPendingImage, rhs: PortalPDFPendingImage) -> Bool {
        lhs.id == rhs.id
    }
}

/// 실제 기기 사진첩의 사진 하나를 Grid에 표시하기 위한 화면 모델입니다.
struct PortalPhotoLibraryItem: Identifiable {
    let asset: PHAsset
    let thumbnail: UIImage

    var id: String {
        asset.localIdentifier
    }
}

/// 사진 선택 결과를 새 이미지 삽입 또는 선택 이미지 교체에 사용할지 구분합니다.
enum PortalPDFImagePickerPurpose {
    case insert
    case replace
}

/// Quick Look 시스템 이미지 편집기에 전달하는 임시 파일입니다.
struct PortalPDFSystemImageEditorItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

/// 선택 이미지와 전용 자르기 화면의 표시 요청을 함께 전달합니다.
struct PortalPDFImageCropEditorItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 자르기 결과 이미지와 기존 이미지 보존 여부를 PDFView 편집 명령으로 전달합니다.
struct PortalPDFImageCropResult {
    let image: UIImage
    let keepsOriginal: Bool
}

/// iOS 공유 시트에 전달할 로컬 PDF 파일입니다.
struct PortalPDFShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

/// PDF 페이지의 이동 방향과 연속/한 장 표시 방식을 함께 정의합니다.
enum PortalPDFDisplayStyle: String, CaseIterable, Identifiable {
    case verticalContinuous
    case horizontalContinuous
    case verticalPaged
    case horizontalPaged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verticalContinuous:
            return "상하 전체 보기"
        case .horizontalContinuous:
            return "좌우 전체 보기"
        case .verticalPaged:
            return "상하 한 장씩 보기"
        case .horizontalPaged:
            return "좌우 한 장씩 보기"
        }
    }

    var displayDirection: PDFDisplayDirection {
        switch self {
        case .verticalContinuous, .verticalPaged:
            return .vertical
        case .horizontalContinuous, .horizontalPaged:
            return .horizontal
        }
    }

    var usesPageViewController: Bool {
        switch self {
        case .verticalContinuous, .horizontalContinuous:
            return false
        case .verticalPaged, .horizontalPaged:
            return true
        }
    }
}

/// PDFView 한 화면에 배치할 페이지 수를 정의합니다.
enum PortalPDFPageLayout: String, CaseIterable, Identifiable {
    case singlePage
    case twoPages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singlePage:
            return "1장 보기"
        case .twoPages:
            return "좌우 2장씩 보기"
        }
    }

    var systemImageName: String {
        switch self {
        case .singlePage:
            return "rectangle"
        case .twoPages:
            return "rectangle.split.2x1"
        }
    }

    /// 기존 이동 스타일의 연속 여부와 조합해 PDFKit 표시 모드를 반환합니다.
    func displayMode(for style: PortalPDFDisplayStyle) -> PDFDisplayMode {
        switch (self, style) {
        case (.singlePage, .verticalContinuous), (.singlePage, .horizontalContinuous):
            return .singlePageContinuous
        case (.singlePage, .verticalPaged), (.singlePage, .horizontalPaged):
            return .singlePage
        case (.twoPages, .verticalContinuous), (.twoPages, .horizontalContinuous):
            return .twoUpContinuous
        case (.twoPages, .verticalPaged), (.twoPages, .horizontalPaged):
            return .twoUp
        }
    }
}

/// PDFView 하단 페이지 정보 알약과 빠른 전체 페이지 목록의 좌우 배치입니다.
enum PortalPDFPageControlPosition: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "왼쪽"
        case .right: return "오른쪽"
        }
    }

    var systemImageName: String {
        switch self {
        case .left: return "align.horizontal.left"
        case .right: return "align.horizontal.right"
        }
    }
}

/// 현재 PDF 페이지 바로 아래에 새 페이지를 삽입하는 1회 명령입니다.
struct PortalPDFPageEditCommand: Equatable {
    let id = UUID()
    let operation: Operation

    enum Operation {
        case addBlankPage
        case duplicateCurrentPage
    }

    static func == (lhs: PortalPDFPageEditCommand, rhs: PortalPDFPageEditCommand) -> Bool {
        lhs.id == rhs.id
    }
}

/// 전체 페이지 목록에서 선택한 PDF 페이지로 한 번만 이동하기 위한 명령입니다.
struct PortalPDFPageNavigationCommand: Equatable {
    let id = UUID()
    let pageIndex: Int

    static func == (lhs: PortalPDFPageNavigationCommand, rhs: PortalPDFPageNavigationCommand) -> Bool {
        lhs.id == rhs.id
    }
}

/// 전체 페이지 편집 화면에서 삭제·복제·순서 변경 후 PDFView를 다시 구성하는 명령입니다.
struct PortalPDFPageStructureRefreshCommand: Equatable {
    let id = UUID()
    let selectedPageIndex: Int

    static func == (lhs: PortalPDFPageStructureRefreshCommand, rhs: PortalPDFPageStructureRefreshCommand) -> Bool {
        lhs.id == rhs.id
    }
}

/// 로컬 PDF 편집본을 다른 앱, AirDrop, 파일 등에 전달하는 시스템 공유 화면입니다.
struct PortalPDFActivityView: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// iOS Quick Look의 시스템 Markup 편집 화면을 SwiftUI에서 표시합니다.
struct PortalPDFSystemImageEditor: UIViewControllerRepresentable {
    let fileURL: URL
    let onEdited: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, onEdited: onEdited, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let previewController = QLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator
        previewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: context.coordinator,
            action: #selector(Coordinator.closeEditor)
        )
        let navigationController = UINavigationController(rootViewController: previewController)
        navigationController.navigationBar.prefersLargeTitles = false
        return navigationController
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let fileURL: URL
        let onEdited: (UIImage) -> Void
        let onCancel: () -> Void
        var didDeliverEditedImage = false

        init(
            fileURL: URL,
            onEdited: @escaping (UIImage) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.fileURL = fileURL
            self.onEdited = onEdited
            self.onCancel = onCancel
        }

        @objc func closeEditor() {
            onCancel()
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            fileURL as NSURL
        }

        func previewController(
            _ controller: QLPreviewController,
            editingModeFor previewItem: QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            .updateContents
        }

        func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: QLPreviewItem) {
            deliverEditedImage(from: fileURL)
        }

        func previewController(
            _ controller: QLPreviewController,
            didSaveEditedCopyOf previewItem: QLPreviewItem,
            at modifiedContentsURL: URL
        ) {
            deliverEditedImage(from: modifiedContentsURL)
        }

        func deliverEditedImage(from url: URL) {
            guard !didDeliverEditedImage,
                  let image = UIImage(contentsOfFile: url.path) else { return }
            didDeliverEditedImage = true
            DispatchQueue.main.async { [onEdited] in
                onEdited(image)
            }
        }
    }
}

/// 현재 선택된 이미지 Annotation에 한 번만 적용할 편집 명령입니다.
struct PortalPDFImageEditCommand: Equatable {
    let id = UUID()
    let operation: Operation

    enum Operation {
        case replace(UIImage)
        case applyCrop(UIImage, keepsOriginal: Bool)
        case resetSize
        case rotateClockwise
        case flipHorizontal
        case openCropEditor
        case openSystemEditor
        case bringToFront
        case sendToBack
    }

    static func == (lhs: PortalPDFImageEditCommand, rhs: PortalPDFImageEditCommand) -> Bool {
        lhs.id == rhs.id
    }
}

/**
 PDFView에 도형 주석을 1회 추가하기 위해 전달하는 선택 도형 모델입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.08.02
 - SeeAlso: ``PortalPDFPreviewView``, ``PortalPDFKitView``
 */
struct PortalPDFPendingShape: Equatable {
    /// 같은 도형을 연속 선택해도 별도 삽입으로 인식하도록 생성 시점마다 부여하는 식별자입니다.
    let id = UUID()
    /// PDF 페이지에 추가할 도형 종류입니다.
    let shapeType: PortalPDFShapeType

    static func == (lhs: PortalPDFPendingShape, rhs: PortalPDFPendingShape) -> Bool {
        lhs.id == rhs.id
    }
}

/// PDFView에 텍스트 박스 주석을 한 번만 추가하기 위한 요청 모델입니다.
struct PortalPDFPendingText: Equatable {
    let id = UUID()
    let occludedViewRect: CGRect?

    init(occludedViewRect: CGRect? = nil) {
        self.occludedViewRect = occludedViewRect
    }

    static func == (lhs: PortalPDFPendingText, rhs: PortalPDFPendingText) -> Bool {
        lhs.id == rhs.id
    }
}

/// 기본 편집 박스에서 PDFView Coordinator로 전달하는 실행 취소·다시 실행 명령입니다.
struct PortalPDFHistoryCommand: Equatable {
    let id = UUID()
    let operation: Operation

    enum Operation: Equatable {
        case undo
        case redo
    }

    static func == (lhs: PortalPDFHistoryCommand, rhs: PortalPDFHistoryCommand) -> Bool {
        lhs.id == rhs.id
    }
}

/**
 PDF 펜 도구에서 선택할 수 있는 색상 옵션입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalPDFPreviewView``
 */
struct PortalPDFPenColor: Identifiable, Equatable {
    /// 기본 또는 사용자 추가 컬러를 구분하는 안정적인 식별자입니다.
    let id: String
    /// VoiceOver와 선택 상태 안내에 사용할 컬러 이름입니다.
    let title: String
    /// 화면과 PDF 주석에 적용할 SwiftUI 컬러입니다.
    let color: Color

    /// 기본으로 제공하는 네 가지 컬러입니다.
    static let defaults: [PortalPDFPenColor] = [
        PortalPDFPenColor(id: "blue", title: "파란색", color: .blue),
        PortalPDFPenColor(id: "red", title: "빨간색", color: .red),
        PortalPDFPenColor(id: "green", title: "초록색", color: .green),
        PortalPDFPenColor(id: "black", title: "검정색", color: .black),
    ]

    /// 팔레트 추가 버튼으로 생성할 기본 사용자 컬러입니다.
    static func custom(index: Int) -> PortalPDFPenColor {
        PortalPDFPenColor(id: "custom-\(UUID().uuidString)", title: "사용자 색상 \(index)", color: .blue)
    }

    /// Color 값 자체가 아니라 식별자로 동일한 팔레트 항목을 판단합니다.
    static func == (lhs: PortalPDFPenColor, rhs: PortalPDFPenColor) -> Bool {
        lhs.id == rhs.id
    }
}

/// PDF 팬슬 선의 굵기 적용 방식입니다.
enum PortalPDFPenType: String, CaseIterable, Identifiable {
    /// 선택한 두께를 선 전체에 동일하게 적용합니다.
    case fixed
    /// Apple Pencil 압력에 따라 선분별 굵기를 변경합니다.
    case pressure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixed:
            return "일반"
        case .pressure:
            return "압력"
        }
    }
}

/// 형광펜 시작·끝 부분의 표시 방식입니다.
enum PortalPDFHighlighterCap: String, CaseIterable, Identifiable {
    /// 선 끝을 반원 형태로 둥글게 표시합니다.
    case round
    /// 선 끝을 과하지 않게 정리된 형태로 표시합니다.
    case soft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .round:
            return "원형 라운드"
        case .soft:
            return "살짝 라운드"
        }
    }

    var lineCapStyle: CGLineCap {
        switch self {
        case .round:
            return .round
        case .soft:
            return .butt
        }
    }
}

/**
 PDF 펜 팔레트를 UserDefaults에 저장·복원하는 로컬 저장소입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.08.03
 - Note: SwiftUI `Color`는 직접 Codable로 저장할 수 없으므로 RGBA 구성 요소로 변환합니다.
 */
enum PortalPDFMarkupTool: String, CaseIterable, Identifiable {
    /// PDF를 스크롤하고 확대/축소하는 기본 보기 모드입니다.
    case view
    /// iPad에서 손가락으로 자유선을 그리는 손글씨 도구입니다.
    case handwriting
    /// iPad에서는 Apple Pencil, iPhone에서는 손가락으로 자유선을 그리는 펜 도구입니다.
    case pen
    /// 노란색 반투명 굵은 선을 그리는 형광펜 도구입니다.
    case highlighter
    /// 선택 색상의 발광 효과를 표시하고 10초 동안 입력이 없으면 모두 사라지는 임시 네온 펜입니다.
    case neon
    /// 선택한 주석을 삭제하는 지우개 도구입니다.
    case eraser
    /// 자유형 영역 안의 편집 주석을 함께 선택하고 이동하는 올가미 도구입니다.
    case lasso
    /// 드래그 영역에 사각형 박스를 추가하는 도구입니다.
    case box
    /// PDF 페이지 위에 서식과 링크를 지원하는 텍스트 입력 박스를 추가하는 도구입니다.
    case text
    /// 사진 보관함에서 선택한 이미지를 PDF 페이지에 추가하는 도구입니다.
    case image

    /// SwiftUI ForEach 식별자입니다.
    var id: String { rawValue }

    /// iPad에는 손가락 손글씨와 Apple Pencil을 모두 표시하고 iPhone에는 기존 펜만 표시합니다.
    static var visibleTools: [PortalPDFMarkupTool] {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return [.view, .handwriting, .pen, .highlighter, .neon, .eraser, .lasso, .box, .text, .image]
        }
        return [.view, .pen, .highlighter, .neon, .eraser, .lasso, .box, .text, .image]
    }

    /// 손가락 손글씨와 Apple Pencil 모드가 공유하는 자유선 편집 기능인지 여부입니다.
    var isInkTool: Bool {
        self == .handwriting || self == .pen || self == .highlighter || self == .neon
    }

    /// PDF 화면에서 이미지·박스·텍스트를 타입과 관계없이 바로 선택할 수 있는 편집 모드입니다.
    var supportsDirectObjectSelection: Bool {
        self == .image || self == .box || self == .text
    }

    /// 화면에 표시할 도구 이름입니다.
    var title: String {
        switch self {
        case .view:
            return "보기"
        case .handwriting:
            return "손글씨"
        case .pen:
            return UIDevice.current.userInterfaceIdiom == .pad ? "팬슬" : "펜"
        case .highlighter:
            return "형광펜"
        case .neon:
            return "네온 펜"
        case .eraser:
            return "지우기"
        case .lasso:
            return "올가미"
        case .box:
            return "박스"
        case .text:
            return "텍스트"
        case .image:
            return "이미지"
        }
    }

    /// 도구 버튼에 표시할 SF Symbol 이름입니다.
    var systemImageName: String {
        switch self {
        case .view:
            return "hand.draw"
        case .handwriting:
            return "scribble"
        case .pen:
            return "pencil.tip"
        case .highlighter:
            return "highlighter"
        case .neon:
            return "light.beacon.max"
        case .eraser:
            return "eraser"
        case .lasso:
            return "lasso"
        case .box:
            return "square"
        case .text:
            return "textbox"
        case .image:
            return "photo.badge.plus"
        }
    }

    /// VoiceOver에서 읽을 도구 설명입니다.
    var accessibilityLabel: String {
        "PDF \(title) 도구"
    }
}

/// Apple Pencil 이중 탭으로 팬슬과 왕복 전환할 PDF 편집 모드입니다.
enum PortalPDFPencilDoubleTapTool: String, CaseIterable, Identifiable {
    case eraser
    case handwriting
    case highlighter
    case lasso
    case box
    case text
    case image

    var id: String { rawValue }

    var markupTool: PortalPDFMarkupTool {
        PortalPDFMarkupTool(rawValue: rawValue) ?? .eraser
    }

    var title: String { markupTool.title }

    var systemImageName: String { markupTool.systemImageName }
}

/**
 박스 도구로 PDF에 추가할 수 있는 도형 종류입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.31
 */
enum PortalPDFShapeType: String, CaseIterable, Identifiable {
    case rectangle
    case roundedRectangle
    case circle
    case triangle
    case hexagon
    case rightArrow
    case star
    case speechBubble
    case diagonalArrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: return "사각형"
        case .roundedRectangle: return "둥근 사각형"
        case .circle: return "원"
        case .triangle: return "삼각형"
        case .hexagon: return "육각형"
        case .rightArrow: return "오른쪽 화살표"
        case .star: return "별"
        case .speechBubble: return "말풍선"
        case .diagonalArrow: return "대각선 화살표"
        }
    }

    var systemImageName: String {
        switch self {
        case .rectangle: return "square"
        case .roundedRectangle: return "app"
        case .circle: return "circle"
        case .triangle: return "triangle"
        case .hexagon: return "hexagon"
        case .rightArrow: return "arrow.right"
        case .star: return "star"
        case .speechBubble: return "bubble.left"
        case .diagonalArrow: return "arrow.up.right"
        }
    }
}

/// 현재 확대 배율에서도 새 이미지가 화면상 일정한 평균 크기로 보이도록 삽입 영역을 계산합니다.
enum PortalPDFImageInsertionLayout {
    static func bounds(
        imageSize: CGSize,
        viewportSize: CGSize,
        scaleFactor: CGFloat,
        pageBounds: CGRect,
        center: CGPoint
    ) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else { return .zero }

        // iPhone과 iPad에서 지나치게 작거나 커지지 않는 화면 기준 평균 표시 크기입니다.
        let displaySize = CGSize(
            width: min(max(viewportSize.width * 0.44, 160), 300),
            height: min(max(viewportSize.height * 0.30, 140), 220)
        )
        let safeScaleFactor = max(scaleFactor, 0.1)
        let maximumPageSize = CGSize(
            width: min(displaySize.width / safeScaleFactor, pageBounds.width * 0.72),
            height: min(displaySize.height / safeScaleFactor, pageBounds.height * 0.55)
        )
        let fittedSize = imageSize.fitted(in: maximumPageSize, allowsUpscaling: true)
        guard fittedSize.width > 0, fittedSize.height > 0 else { return .zero }

        var result = CGRect(
            x: center.x - fittedSize.width / 2,
            y: center.y - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
        // 중앙이 페이지 가장자리와 가까운 경우 비율을 자르지 않고 위치만 페이지 안으로 이동합니다.
        let dx = min(max(pageBounds.minX - result.minX, 0), pageBounds.maxX - result.maxX)
        let dy = min(max(pageBounds.minY - result.minY, 0), pageBounds.maxY - result.maxY)
        result = result.offsetBy(dx: dx, dy: dy)
        return result
    }
}

/// 펜 입력 중 PDFKit의 텍스트 선택·복사 메뉴가 편집 제스처보다 먼저 나타나지 않도록 제어합니다.
