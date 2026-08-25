//
// PortalPDFImageAnnotation.swift
// NF
//
// Editable image annotations and image transformations.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

final class PortalPDFImageAnnotation: PDFAnnotation, PortalPDFTransformableAnnotation {
    static let metadataPrefix = "NF_EDITABLE_IMAGE_V1:"
    struct Metadata: Codable {
        let imageData: Data
        let bounds: CGRect
        let rotationAngle: Double
        let isHorizontallyFlipped: Bool
        /// FileManager의 `ImagesObject`처럼 GIF 원본 프레임 컨테이너를 정지 이미지와 별도로 보존합니다.
        let animatedGIFData: Data?

        init(
            imageData: Data,
            bounds: CGRect,
            rotationAngle: Double,
            isHorizontallyFlipped: Bool,
            animatedGIFData: Data? = nil
        ) {
            self.imageData = imageData
            self.bounds = bounds
            self.rotationAngle = rotationAngle
            self.isHorizontallyFlipped = isHorizontallyFlipped
            self.animatedGIFData = animatedGIFData
        }
    }
    struct HistoryState {
        fileprivate let image: UIImage
        fileprivate let persistedImageData: Data
        fileprivate let bounds: CGRect
        fileprivate let rotationAngle: CGFloat
        fileprivate let isHorizontallyFlipped: Bool
        fileprivate let displayScaleFactor: CGFloat
        fileprivate let animatedGIFData: Data?
    }
    /// 축소 시 이미지 본문이 유지되는 최소 변 길이입니다.
    static let minimumContentSide: CGFloat = 20
    /// 이미지 바깥에 표시하는 점선 선택 영역의 간격입니다.
    static let selectionPadding: CGFloat = 12
    /// 이미지 오른쪽 상단에 표시하는 크기·회전 조절 핸들의 PDF Page 기준 지름입니다.
    static let transformHandleDiameter: CGFloat = 24
    /// 이미지 선택선의 상·하·좌·우 면 중앙에 표시하는 크기 조절점의 화면 기준 한 변 길이입니다.
    static let resizeHandleSide: CGFloat = 10
    /// 조절 핸들이 선택 박스 바깥에 분리되어 보이도록 적용하는 여백입니다.
    static let transformHandleMargin: CGFloat = 3
    /// 이미지 왼쪽 상단에 표시하는 삭제 버튼의 PDF Page 기준 지름입니다.
    static let deleteHandleDiameter: CGFloat = 24
    /// 삭제 버튼이 점선 편집 영역 바깥에 분리되어 보이도록 적용하는 여백입니다.
    static let deleteHandleMargin: CGFloat = 3
    /// PDFKit Annotation 클리핑을 막기 위해 외곽 렌더링 영역에 더하는 여유입니다.
    static let clippingSafetyMargin: CGFloat = 3
    /// 매우 축소된 상태에서 버튼용 Annotation 영역이 과도하게 커지는 것을 막는 최소 보정 배율입니다.
    static let minimumEditingDisplayScaleFactor: CGFloat = 0.5
    /// PDF Annotation이 렌더링할 이미지입니다.
    let image: UIImage
    /// 재진입 시 편집 객체를 복원하기 위해 PDF Annotation 메타데이터에 넣을 압축 이미지입니다.
    let persistedImageData: Data
    /// 화면 애니메이션용 GIF 원본입니다. PDF 내보내기에서는 첫 프레임이 사용됩니다.
    let animatedGIFData: Data?
    /// 실제 이미지 본문 영역입니다. PDFKit의 bounds는 회전 후 이미지·점선·핸들을 모두 담는 렌더링 안전 영역입니다.
    var imageBounds: CGRect
    /// 이미지 편집 모드에서 점선 선택 박스를 표시할지 여부입니다.
    var isPortalSelected: Bool = false
    /// PDF 확대·축소와 반대로 보정해 편집 버튼의 화면상 크기를 일정하게 유지하는 배율입니다.
    var editingDisplayScaleFactor: CGFloat = 1
    /// 선택 점선의 두께와 간격을 화면상 동일하게 유지하기 위한 실제 PDF 확대 배율입니다.
    var selectionDisplayScaleFactor: CGFloat = 1
    var displayedSelectionLineWidth: CGFloat {
        1 / selectionDisplayScaleFactor
    }
    var displayedSelectionDashLengths: [CGFloat] {
        [4 / selectionDisplayScaleFactor, 3 / selectionDisplayScaleFactor]
    }
    var displayedSelectionPadding: CGFloat {
        Self.selectionPadding / selectionDisplayScaleFactor
    }
    /// 이미지 본문만 좌우 반전해 표시할지 여부입니다. 선택선과 편집 핸들은 반전하지 않습니다.
    var isHorizontallyFlipped: Bool = false
    /// 이미지 Annotation에 적용할 회전 각도입니다.
    var rotationAngle: CGFloat = 0 {
        didSet {
            guard oldValue != rotationAngle else { return }
            constrainToPageIfNeeded()
            updatePresentationBounds()
        }
    }

    /// 사용자 제스처로 이동·확대·축소하는 이미지 본문 영역입니다.
    var editingBounds: CGRect {
        get { imageBounds }
        set {
            imageBounds = newValue
            constrainToPageIfNeeded()
            updatePresentationBounds()
        }
    }

    /**
     이미지 주석을 생성합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - image: PDF 위에 그릴 이미지입니다.
        - bounds: PDF Page 좌표계 기준 이미지 본문 표시 영역입니다. 편집용 외곽 영역은 내부에서 확장합니다.
     */
    convenience init(image: UIImage, bounds: CGRect) {
        self.init(
            image: image,
            persistedImageData: image.jpegData(compressionQuality: 0.84) ?? image.pngData() ?? Data(),
            bounds: bounds,
            animatedGIFData: nil
        )
    }

    init(
        image: UIImage,
        persistedImageData: Data,
        bounds: CGRect,
        animatedGIFData: Data? = nil
    ) {
        self.image = image
        self.persistedImageData = persistedImageData
        self.animatedGIFData = animatedGIFData
        self.imageBounds = bounds
        // 화면 표시는 원본 CGImage 오버레이가 담당합니다. Stamp는 숨김·빈 bounds 상태에서도
        // PDFKit이 고배율 래스터 효과 레이어를 만들 수 있어 런타임 객체는 Square로 유지합니다.
        super.init(bounds: Self.presentationBounds(for: bounds, rotation: 0), forType: .square, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
        prepareForPersistence()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// PDF에서 다시 읽은 일반 Stamp Annotation을 선택·이동 가능한 이미지 객체로 복원합니다.
    static func restored(from annotation: PDFAnnotation) -> PortalPDFImageAnnotation? {
        guard let contents = annotation.contents,
              contents.hasPrefix(metadataPrefix),
              let data = Data(base64Encoded: String(contents.dropFirst(metadataPrefix.count))),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              let image = UIImage(data: metadata.imageData) else { return nil }
        let restored = PortalPDFImageAnnotation(
            image: image,
            persistedImageData: metadata.imageData,
            bounds: metadata.bounds,
            animatedGIFData: metadata.animatedGIFData
        )
        restored.rotationAngle = CGFloat(metadata.rotationAngle)
        restored.isHorizontallyFlipped = metadata.isHorizontallyFlipped
        restored.isPortalSelected = false
        restored.prepareForPersistence()
        return restored
    }

    /// Undo 히스토리에는 PDFAnnotation 대신 래스터 참조와 편집 값만 보관합니다.
    var historyState: HistoryState {
        HistoryState(
            image: image,
            persistedImageData: persistedImageData,
            bounds: imageBounds,
            rotationAngle: rotationAngle,
            isHorizontallyFlipped: isHorizontallyFlipped,
            displayScaleFactor: selectionDisplayScaleFactor,
            animatedGIFData: animatedGIFData
        )
    }

    static func annotation(from state: HistoryState) -> PortalPDFImageAnnotation {
        let clone = PortalPDFImageAnnotation(
            image: state.image,
            persistedImageData: state.persistedImageData,
            bounds: state.bounds,
            animatedGIFData: state.animatedGIFData
        )
        clone.rotationAngle = state.rotationAngle
        clone.isHorizontallyFlipped = state.isHorizontallyFlipped
        clone.isPortalSelected = false
        clone.updateEditingDisplayScaleFactor(state.displayScaleFactor)
        clone.prepareForPersistence()
        return clone
    }

    func historyClone() -> PortalPDFImageAnnotation {
        Self.annotation(from: historyState)
    }

    /// PDFKit 렌더 캐시를 갱신하는 이미지 편집 명령에서 사용할 원본 본문 이미지입니다.
    var contentImageForEditing: UIImage {
        image
    }

    /// 추가 편집 바의 회전 명령에 사용할 이미지 본문만 90도 회전한 래스터입니다.
    func clockwiseRotatedContentImage() -> UIImage {
        let rotatedSize = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: rotatedSize, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
            context.rotate(by: .pi / 2)
            image.draw(in: CGRect(
                x: -image.size.width / 2,
                y: -image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            ))
        }
    }

    /// 현재 위치·크기·회전·반전 상태를 PDF Annotation 메타데이터에 갱신합니다.
    func prepareForPersistence() {
        let metadata = Metadata(
            imageData: persistedImageData,
            bounds: imageBounds,
            rotationAngle: Double(rotationAngle),
            isHorizontallyFlipped: isHorizontallyFlipped,
            animatedGIFData: animatedGIFData
        )
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        contents = Self.metadataPrefix + data.base64EncodedString()
        userName = "NF Editable Image"
    }

    /// 현재 PDFView 배율을 편집 버튼 렌더링에 반영합니다.
    @discardableResult
    func updateEditingDisplayScaleFactor(_ scaleFactor: CGFloat) -> Bool {
        let normalizedScaleFactor = max(scaleFactor, 0.1)
        guard selectionDisplayScaleFactor != normalizedScaleFactor
                || editingDisplayScaleFactor != max(scaleFactor, Self.minimumEditingDisplayScaleFactor) else {
            return false
        }
        selectionDisplayScaleFactor = normalizedScaleFactor
        editingDisplayScaleFactor = max(scaleFactor, Self.minimumEditingDisplayScaleFactor)
        // 확대 배율에 따라 커지거나 작아진 점선·핸들이 Annotation 렌더 영역 밖에서 잘리지 않도록 갱신합니다.
        updatePresentationBounds()
        return true
    }

    /**
     PDFKit이 Annotation을 그릴 때 이미지 본문을 직접 렌더링합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - box: PDF 표시 Box 타입입니다.
        - context: PDFKit 렌더링 CGContext 입니다.
     */
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = image.cgImage else { return }
        let imageRect = contentRect
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        context.saveGState()
        // PDFAnnotation의 draw 컨텍스트는 PDF 페이지 좌표계입니다. 이미지 본문과
        // 선택 UI 모두 Annotation bounds의 절대 페이지 좌표를 사용해야 합니다.
        context.translateBy(x: imageBounds.midX, y: imageBounds.midY)
        context.rotate(by: rotationAngle)
        context.translateBy(x: -imageBounds.midX, y: -imageBounds.midY)
        // PDFKit이 전달하는 Annotation CGContext는 이미 PDF 페이지 방향을 적용합니다.
        // 여기서 Y축을 다시 뒤집으면 PhotosPicker에서 정규화한 이미지가 상하 반전됩니다.
        context.saveGState()
        if isHorizontallyFlipped {
            context.translateBy(x: imageBounds.midX, y: imageBounds.midY)
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: -imageBounds.midX, y: -imageBounds.midY)
        }
        context.draw(cgImage, in: imageRect)
        context.restoreGState()
        drawSelectionOutlineIfNeeded(in: context)
        context.restoreGState()
    }

    /**
     이미지 편집 활성 상태에서 이미지 전체 영역에 점선 선택 박스를 그립니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - context: PDFKit 렌더링 CGContext 입니다.
     */
    func drawSelectionOutlineIfNeeded(in context: CGContext) {
        guard isPortalSelected else { return }
        // 본문 이미지보다 바깥에 점선을 두고, 오른쪽 상단 핸들은 점선 바깥에 둡니다.
        let outlineInset = 1.5 / selectionDisplayScaleFactor
        let outlineRect = annotationOutlineRect.insetBy(dx: outlineInset, dy: outlineInset)
        context.saveGState()
        // 점선은 크기·회전 핸들과 동일한 파란색을 사용합니다. 삭제·크기 변경 핸들의
        // 모양과 색상 구현은 기존 상태를 그대로 유지합니다.
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(displayedSelectionLineWidth)
        context.setLineDash(phase: 0, lengths: displayedSelectionDashLengths)
        context.stroke(outlineRect)
        // 점선 상태가 삭제·크기 변경 아이콘의 선으로 전파되지 않도록 복원합니다.
        context.setLineDash(phase: 0, lengths: [])
        drawResizeHandles(in: context)
        drawDeleteHandle(in: context)
        drawTransformHandle(in: context)
        context.restoreGState()
    }

    /// 이미지 선택선의 네 면 중앙에만 축별 크기 조절점을 표시합니다.
    func drawResizeHandles(in context: CGContext) {
        let side = displayedResizeHandleSide
        let halfSide = side / 2
        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(displayedSelectionLineWidth)
        unrotatedResizeHandleCenters.values.forEach { center in
            let handleRect = CGRect(
                x: center.x - halfSide,
                y: center.y - halfSide,
                width: side,
                height: side
            )
            context.fill(handleRect)
            context.stroke(handleRect)
        }
        context.restoreGState()
    }

    /// 선택 이미지 왼쪽 상단에 삭제 버튼을 표시합니다.
    func drawDeleteHandle(in context: CGContext) {
        let center = unrotatedDeleteHandleCenter
        let diameter = displayedDeleteHandleDiameter
        let radius = diameter / 2
        let buttonRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: diameter,
            height: diameter
        )
        context.saveGState()
        context.setFillColor(UIColor.systemRed.cgColor)
        context.fillEllipse(in: buttonRect)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(2 / editingDisplayScaleFactor)
        let iconInset = 7 / editingDisplayScaleFactor
        context.move(to: CGPoint(x: buttonRect.minX + iconInset, y: buttonRect.minY + iconInset))
        context.addLine(to: CGPoint(x: buttonRect.maxX - iconInset, y: buttonRect.maxY - iconInset))
        context.move(to: CGPoint(x: buttonRect.maxX - iconInset, y: buttonRect.minY + iconInset))
        context.addLine(to: CGPoint(x: buttonRect.minX + iconInset, y: buttonRect.maxY - iconInset))
        context.strokePath()
        context.restoreGState()
    }

    /**
     선택 이미지 오른쪽 상단에 크기·회전 조절 핸들을 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.31
     - Parameters:
        - context: PDFKit Annotation 렌더링 CGContext 입니다.
     */
    func drawTransformHandle(in context: CGContext) {
        let center = unrotatedTransformHandleCenter
        let diameter = displayedTransformHandleDiameter
        let radius = diameter / 2
        let handleRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: diameter,
            height: diameter
        )
        context.saveGState()
        context.setFillColor(UIColor.systemBlue.cgColor)
        context.fillEllipse(in: handleRect)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(1.8 / editingDisplayScaleFactor)
        let borderInset = 0.9 / editingDisplayScaleFactor
        context.strokeEllipse(in: handleRect.insetBy(dx: borderInset, dy: borderInset))

        let iconInset = 7 / editingDisplayScaleFactor
        let arrowHeadLength = 4 / editingDisplayScaleFactor
        let lowerLeft = CGPoint(x: handleRect.minX + iconInset, y: handleRect.minY + iconInset)
        let upperRight = CGPoint(x: handleRect.maxX - iconInset, y: handleRect.maxY - iconInset)
        context.move(to: lowerLeft)
        context.addLine(to: upperRight)
        context.move(to: CGPoint(x: upperRight.x - arrowHeadLength, y: upperRight.y))
        context.addLine(to: upperRight)
        context.addLine(to: CGPoint(x: upperRight.x, y: upperRight.y - arrowHeadLength))
        context.move(to: CGPoint(x: lowerLeft.x + arrowHeadLength, y: lowerLeft.y))
        context.addLine(to: lowerLeft)
        context.addLine(to: CGPoint(x: lowerLeft.x, y: lowerLeft.y + arrowHeadLength))
        context.strokePath()
        context.restoreGState()
    }

    /**
     PDF Page 좌표가 선택 이미지 오른쪽 상단 조절 핸들 범위에 포함되는지 확인합니다.
     - Version: 1.0.0
     - Date: 2026.07.31
     - Parameters:
        - point: 확인할 PDF Page 좌표입니다.
        - scaleFactor: 화면 기준 터치 반경을 보정할 PDFView 확대 배율입니다.
     - Returns: 조절 핸들 터치로 판단되면 `true` 입니다.
     */
    func isTransformHandleHit(_ point: CGPoint, scaleFactor: CGFloat) -> Bool {
        updateEditingDisplayScaleFactor(scaleFactor)
        let center = pageTransformHandleCenter
        let screenAdjustedRadius = 22 / max(scaleFactor, 0.01)
        let hitRadius = max(displayedTransformHandleDiameter / 2, screenAdjustedRadius)
        return hypot(point.x - center.x, point.y - center.y) <= hitRadius
    }

    /// 화면 터치 위치와 가장 가까운 상·하·좌·우 면 중앙 크기 조절점을 반환합니다.
    func resizeHandle(at point: CGPoint, scaleFactor: CGFloat) -> PortalPDFResizeHandle? {
        updateEditingDisplayScaleFactor(scaleFactor)
        let center = imageBounds.center
        let offset = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let cosine = cos(rotationAngle)
        let sine = sin(rotationAngle)
        let unrotatedPoint = CGPoint(
            x: center.x + offset.x * cosine + offset.y * sine,
            y: center.y - offset.x * sine + offset.y * cosine
        )
        let screenAdjustedRadius = 22 / max(scaleFactor, 0.01)
        let hitRadius = max(displayedResizeHandleSide / 2, screenAdjustedRadius)
        return unrotatedResizeHandleCenters
            .map { (handle: $0.key, distance: hypot(unrotatedPoint.x - $0.value.x, unrotatedPoint.y - $0.value.y)) }
            .filter { $0.distance <= hitRadius }
            .min(by: { $0.distance < $1.distance })?
            .handle
    }

    /// 선택 이미지 왼쪽 상단 삭제 버튼의 터치 범위를 확인합니다.
    func isDeleteHandleHit(_ point: CGPoint, scaleFactor: CGFloat) -> Bool {
        updateEditingDisplayScaleFactor(scaleFactor)
        let center = pageDeleteHandleCenter
        let screenAdjustedRadius = 22 / max(scaleFactor, 0.01)
        let hitRadius = max(displayedDeleteHandleDiameter / 2, screenAdjustedRadius)
        return hypot(point.x - center.x, point.y - center.y) <= hitRadius
    }

    /// 회전 전 PDF 페이지 좌표계의 오른쪽 상단 조절 핸들 중심입니다.
    var unrotatedTransformHandleCenter: CGPoint {
        let outlineRect = annotationOutlineRect
        let offset = displayedTransformHandleDiameter / 2 + displayedTransformHandleMargin
        return CGPoint(x: outlineRect.maxX + offset, y: outlineRect.maxY + offset)
    }

    /// 회전 전 PDF 페이지 좌표계의 왼쪽 상단 삭제 버튼 중심입니다.
    var unrotatedDeleteHandleCenter: CGPoint {
        let outlineRect = annotationOutlineRect
        let offset = displayedDeleteHandleDiameter / 2 + displayedDeleteHandleMargin
        return CGPoint(x: outlineRect.minX - offset, y: outlineRect.maxY + offset)
    }

    var displayedTransformHandleDiameter: CGFloat {
        Self.transformHandleDiameter / editingDisplayScaleFactor
    }

    var displayedResizeHandleSide: CGFloat {
        Self.resizeHandleSide / editingDisplayScaleFactor
    }

    var displayedDeleteHandleDiameter: CGFloat {
        Self.deleteHandleDiameter / editingDisplayScaleFactor
    }

    var displayedTransformHandleMargin: CGFloat {
        Self.transformHandleMargin / editingDisplayScaleFactor
    }

    var displayedDeleteHandleMargin: CGFloat {
        Self.deleteHandleMargin / editingDisplayScaleFactor
    }

    /// PDF 페이지 좌표계에서 실제 이미지가 그려지는 본문 영역입니다.
    var contentRect: CGRect {
        imageBounds
    }

    /// 이미지 편집이 활성화되었음을 안내하는 전체 주석 영역입니다. 점선은 이 영역을 따라 그려집니다.
    var annotationOutlineRect: CGRect {
        contentRect.insetBy(dx: -displayedSelectionPadding, dy: -displayedSelectionPadding)
    }

    /// 회전 전 PDF 페이지 좌표계에서 이미지 네 면 중앙 크기 조절점의 중심입니다.
    var unrotatedResizeHandleCenters: [PortalPDFResizeHandle: CGPoint] {
        let outlineRect = annotationOutlineRect
        return [
            .topCenter: CGPoint(x: outlineRect.midX, y: outlineRect.maxY),
            .middleLeft: CGPoint(x: outlineRect.minX, y: outlineRect.midY),
            .middleRight: CGPoint(x: outlineRect.maxX, y: outlineRect.midY),
            .bottomCenter: CGPoint(x: outlineRect.midX, y: outlineRect.minY),
        ]
    }

    /// 현재 회전 각도를 반영한 PDF Page 좌표계의 오른쪽 상단 조절 핸들 중심입니다.
    var pageTransformHandleCenter: CGPoint {
        let center = CGPoint(x: imageBounds.midX, y: imageBounds.midY)
        let offset = CGPoint(
            x: unrotatedTransformHandleCenter.x - center.x,
            y: unrotatedTransformHandleCenter.y - center.y
        )
        let cosine = cos(rotationAngle)
        let sine = sin(rotationAngle)
        return CGPoint(
            x: center.x + offset.x * cosine - offset.y * sine,
            y: center.y + offset.x * sine + offset.y * cosine
        )
    }

    var transformHandleCenter: CGPoint {
        pageTransformHandleCenter
    }

    /// 현재 회전 각도를 반영한 PDF 페이지 좌표계의 왼쪽 상단 삭제 버튼 중심입니다.
    var pageDeleteHandleCenter: CGPoint {
        let center = CGPoint(x: imageBounds.midX, y: imageBounds.midY)
        let offset = CGPoint(
            x: unrotatedDeleteHandleCenter.x - center.x,
            y: unrotatedDeleteHandleCenter.y - center.y
        )
        let cosine = cos(rotationAngle)
        let sine = sin(rotationAngle)
        return CGPoint(
            x: center.x + offset.x * cosine - offset.y * sine,
            y: center.y + offset.x * sine + offset.y * cosine
        )
    }

    var deleteHandleCenter: CGPoint {
        pageDeleteHandleCenter
    }

    func constrainedEditingBounds(_ candidate: CGRect, in container: CGRect) -> CGRect {
        Self.constrainedContentBounds(
            candidate,
            rotation: rotationAngle,
            selectionPadding: displayedSelectionPadding,
            in: container
        )
    }

    func constrainToPageIfNeeded() {
        guard let page else { return }
        imageBounds = constrainedEditingBounds(imageBounds, in: page.bounds(for: .cropBox))
    }

    func updatePresentationBounds() {
        guard !PortalPDFInkDisplaySuppression.isSuppressed(self) else {
            bounds = .zero
            return
        }
        bounds = Self.presentationBounds(
            for: imageBounds,
            rotation: rotationAngle,
            selectionPadding: displayedSelectionPadding
        )
    }

    static func presentationBounds(
        for contentBounds: CGRect,
        rotation: CGFloat,
        selectionPadding: CGFloat = PortalPDFImageAnnotation.selectionPadding
    ) -> CGRect {
        let outlineRect = contentBounds.insetBy(dx: -selectionPadding, dy: -selectionPadding)
        let reservedResizePadding = resizeHandleSide / minimumEditingDisplayScaleFactor / 2
        let resizeBounds = outlineRect.insetBy(dx: -reservedResizePadding, dy: -reservedResizePadding)
        // 축소 상태에서 역보정된 버튼도 Annotation 밖으로 잘리지 않도록 최대 표시 크기를 예약합니다.
        let reservedHandleDiameter = transformHandleDiameter / minimumEditingDisplayScaleFactor
        let reservedHandleMargin = transformHandleMargin / minimumEditingDisplayScaleFactor
        let handleOffset = reservedHandleDiameter / 2 + reservedHandleMargin
        let handleCenter = CGPoint(x: outlineRect.maxX + handleOffset, y: outlineRect.maxY + handleOffset)
        let handleRect = CGRect(
            x: handleCenter.x - reservedHandleDiameter / 2,
            y: handleCenter.y - reservedHandleDiameter / 2,
            width: reservedHandleDiameter,
            height: reservedHandleDiameter
        )
        let reservedDeleteDiameter = deleteHandleDiameter / minimumEditingDisplayScaleFactor
        let reservedDeleteMargin = deleteHandleMargin / minimumEditingDisplayScaleFactor
        let deleteHandleOffset = reservedDeleteDiameter / 2 + reservedDeleteMargin
        let deleteHandleCenter = CGPoint(x: outlineRect.minX - deleteHandleOffset, y: outlineRect.maxY + deleteHandleOffset)
        let deleteHandleRect = CGRect(
            x: deleteHandleCenter.x - reservedDeleteDiameter / 2,
            y: deleteHandleCenter.y - reservedDeleteDiameter / 2,
            width: reservedDeleteDiameter,
            height: reservedDeleteDiameter
        )
        return resizeBounds
            .union(handleRect)
            .union(deleteHandleRect)
            .insetBy(dx: -clippingSafetyMargin, dy: -clippingSafetyMargin)
            .rotatedBoundingBox(around: contentBounds.center, by: rotation)
    }

    static func constrainedContentBounds(
        _ candidate: CGRect,
        rotation: CGFloat,
        selectionPadding: CGFloat = PortalPDFImageAnnotation.selectionPadding,
        in container: CGRect
    ) -> CGRect {
        var adjusted = candidate
        let visibleBounds = presentationBounds(
            for: adjusted,
            rotation: rotation,
            selectionPadding: selectionPadding
        )
        let fittingScale = min(1, container.width / visibleBounds.width, container.height / visibleBounds.height)
        if fittingScale < 1 {
            adjusted = adjusted.scaled(around: adjusted.center, by: fittingScale)
        }
        let constrainedVisibleBounds = presentationBounds(
            for: adjusted,
            rotation: rotation,
            selectionPadding: selectionPadding
        )
        let dx = min(max(container.minX - constrainedVisibleBounds.minX, 0), container.maxX - constrainedVisibleBounds.maxX)
        let dy = min(max(container.minY - constrainedVisibleBounds.minY, 0), container.maxY - constrainedVisibleBounds.maxY)
        return adjusted.offsetBy(dx: dx, dy: dy)
    }
}
