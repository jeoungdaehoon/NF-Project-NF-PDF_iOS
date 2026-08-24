//
// PortalPDFShapeAnnotation.swift
// NF
//
// Shape path construction and editable shape annotations.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

enum PortalPDFShapePath {
    /**
     지정 영역 안에 선택 도형의 경로를 생성합니다.
     - Parameters:
        - shapeType: 생성할 도형 종류입니다.
        - rect: 도형을 채울 좌표 영역입니다.
        - yAxisPointsDown: UIKit 화면처럼 아래 방향이 양수인 좌표계인지 여부입니다.
     */
    static func make(
        _ shapeType: PortalPDFShapeType,
        in rect: CGRect,
        yAxisPointsDown: Bool
    ) -> UIBezierPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x,
                y: yAxisPointsDown
                    ? rect.minY + rect.height * y
                    : rect.maxY - rect.height * y
            )
        }

        func polygon(_ points: [(CGFloat, CGFloat)]) -> UIBezierPath {
            let path = UIBezierPath()
            guard let first = points.first else { return path }
            path.move(to: point(first.0, first.1))
            points.dropFirst().forEach { path.addLine(to: point($0.0, $0.1)) }
            path.close()
            return path
        }

        switch shapeType {
        case .rectangle:
            return UIBezierPath(rect: rect)
        case .roundedRectangle:
            return UIBezierPath(
                roundedRect: rect,
                cornerRadius: min(rect.width, rect.height) * 0.16
            )
        case .circle:
            return UIBezierPath(ovalIn: rect)
        case .triangle:
            return polygon([(0.5, 0), (1, 1), (0, 1)])
        case .hexagon:
            return polygon([(0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5)])
        case .rightArrow:
            return polygon([
                (0, 0.30), (0.62, 0.30), (0.62, 0),
                (1, 0.5), (0.62, 1), (0.62, 0.70), (0, 0.70)
            ])
        case .star:
            let center = CGPoint(x: 0.5, y: 0.52)
            let vertices: [(CGFloat, CGFloat)] = (0..<10).map { index in
                let angle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
                let radius: CGFloat = index.isMultiple(of: 2) ? 0.50 : 0.22
                return (
                    center.x + cos(angle) * radius,
                    center.y + sin(angle) * radius
                )
            }
            return polygon(vertices)
        case .speechBubble:
            let path = UIBezierPath()
            path.move(to: point(0.14, 0.05))
            path.addLine(to: point(0.86, 0.05))
            path.addQuadCurve(to: point(0.96, 0.17), controlPoint: point(0.96, 0.05))
            path.addLine(to: point(0.96, 0.62))
            path.addQuadCurve(to: point(0.86, 0.74), controlPoint: point(0.96, 0.74))
            path.addLine(to: point(0.43, 0.74))
            path.addLine(to: point(0.22, 0.96))
            path.addLine(to: point(0.26, 0.74))
            path.addLine(to: point(0.14, 0.74))
            path.addQuadCurve(to: point(0.04, 0.62), controlPoint: point(0.04, 0.74))
            path.addLine(to: point(0.04, 0.17))
            path.addQuadCurve(to: point(0.14, 0.05), controlPoint: point(0.04, 0.05))
            path.close()
            return path
        case .diagonalArrow:
            return polygon([
                (0.45, 0), (1, 0), (1, 0.55),
                (0.84, 0.39), (0.36, 0.87), (0.13, 0.64), (0.61, 0.16)
            ])
        }
    }
}

/**
 PDF 페이지 위에서 다시 편집할 수 있는 텍스트 박스 Annotation 입니다.
 텍스트와 웹 어시스트에 대응하는 스타일을 PDF 메타데이터에 함께 저장합니다.
 */
final class PortalPDFShapeAnnotation: PDFAnnotation, PortalPDFTransformableAnnotation {
    static let metadataPrefix = "NF_EDITABLE_SHAPE_V1:"
    struct Metadata: Codable {
        let shapeType: String
        let bounds: CGRect
        let lineWidth: Double
        let lineColorRGBA: [Double]
        let fillColorRGBA: [Double]
        let rotationAngle: Double
    }
    /// 첨부 예시처럼 도형 테두리 위에 표시하는 사각 조절점의 화면 기준 한 변 길이입니다.
    static let resizeHandleSide: CGFloat = 10
    /// 선택 도형 왼쪽 상단에 표시하는 삭제 버튼의 PDF Page 기준 지름입니다.
    static let deleteHandleDiameter: CGFloat = 24
    /// 삭제 버튼이 점선 편집 영역 바깥에 분리되어 보이도록 적용하는 여백입니다.
    static let deleteHandleMargin: CGFloat = 3
    static let clippingSafetyMargin: CGFloat = 3
    static let minimumEditingDisplayScaleFactor: CGFloat = 0.5
    let shapeType: PortalPDFShapeType
    let portalLineWidth: CGFloat
    /// 도형 본문에 그릴 선 색상입니다.
    var lineColor: UIColor {
        didSet { updateStoredMetadata() }
    }
    /// 도형 본문에 채울 배경 색상입니다.
    var fillColor: UIColor {
        didSet { updateStoredMetadata() }
    }
    /// 실제 도형 본문 영역입니다. PDFKit이 사용하는 bounds는 회전 후 클리핑을 막기 위한 외곽 영역입니다.
    var shapeBounds: CGRect
    var isPortalSelected: Bool = false {
        didSet { updatePresentationBounds() }
    }
    /// PDF 확대·축소와 반대로 보정해 조절점과 삭제 버튼의 화면상 크기를 일정하게 유지합니다.
    var editingDisplayScaleFactor: CGFloat = 1
    var selectionDisplayScaleFactor: CGFloat = 1
    var rotationAngle: CGFloat = 0 {
        didSet {
            guard oldValue != rotationAngle else { return }
            constrainToPageIfNeeded()
            updatePresentationBounds()
            updateStoredMetadata()
        }
    }

    var editingBounds: CGRect {
        get { shapeBounds }
        set {
            shapeBounds = newValue
            constrainToPageIfNeeded()
            updatePresentationBounds()
            updateStoredMetadata()
        }
    }

    init(
        shapeType: PortalPDFShapeType,
        bounds: CGRect,
        lineWidth: CGFloat,
        lineColor: UIColor = .systemOrange,
        fillColor: UIColor = UIColor.systemOrange.withAlphaComponent(0.14)
    ) {
        self.shapeType = shapeType
        self.portalLineWidth = lineWidth
        self.lineColor = lineColor
        self.fillColor = fillColor
        self.shapeBounds = bounds
        super.init(bounds: Self.presentationBounds(for: bounds, rotation: 0), forType: .stamp, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
        updateStoredMetadata()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// PDF에서 다시 읽은 일반 Stamp Annotation을 선택·이동 가능한 도형 객체로 복원합니다.
    static func restored(from annotation: PDFAnnotation) -> PortalPDFShapeAnnotation? {
        guard let contents = annotation.contents,
              contents.hasPrefix(metadataPrefix),
              let data = Data(base64Encoded: String(contents.dropFirst(metadataPrefix.count))),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              let shapeType = PortalPDFShapeType(rawValue: metadata.shapeType),
              let lineColor = UIColor.portalColor(rgba: metadata.lineColorRGBA),
              let fillColor = UIColor.portalColor(rgba: metadata.fillColorRGBA) else { return nil }
        let restored = PortalPDFShapeAnnotation(
            shapeType: shapeType,
            bounds: metadata.bounds,
            lineWidth: CGFloat(metadata.lineWidth),
            lineColor: lineColor,
            fillColor: fillColor
        )
        restored.rotationAngle = CGFloat(metadata.rotationAngle)
        restored.isPortalSelected = false
        return restored
    }

    func updateStoredMetadata() {
        let metadata = Metadata(
            shapeType: shapeType.rawValue,
            bounds: shapeBounds,
            lineWidth: Double(portalLineWidth),
            lineColorRGBA: lineColor.portalRGBA,
            fillColorRGBA: fillColor.portalRGBA,
            rotationAngle: Double(rotationAngle)
        )
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        contents = Self.metadataPrefix + data.base64EncodedString()
        userName = "NF Editable Shape"
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let inset = portalLineWidth / 2 + 1
        // PDFAnnotation의 draw 컨텍스트는 Annotation 로컬 좌표가 아니라 PDF 페이지 좌표입니다.
        // bounds.origin을 반영하지 않으면 도형이 페이지 좌하단에 그려지거나 클리핑됩니다.
        let drawingBounds = shapeBounds.insetBy(dx: inset, dy: inset)
        let path = PortalPDFShapePath.make(shapeType, in: drawingBounds, yAxisPointsDown: false)
        context.saveGState()
        context.translateBy(x: shapeBounds.midX, y: shapeBounds.midY)
        context.rotate(by: rotationAngle)
        context.translateBy(x: -shapeBounds.midX, y: -shapeBounds.midY)
        context.addPath(path.cgPath)
        context.setFillColor(fillColor.cgColor)
        context.setStrokeColor(lineColor.cgColor)
        context.setLineWidth(portalLineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        drawSelectionOutlineIfNeeded(in: context)
        context.restoreGState()
    }

    var displayedSelectionLineWidth: CGFloat {
        1 / selectionDisplayScaleFactor
    }

    var displayedSelectionDashLengths: [CGFloat] {
        [4 / selectionDisplayScaleFactor, 3 / selectionDisplayScaleFactor]
    }

    var displayedResizeHandleSide: CGFloat {
        Self.resizeHandleSide / editingDisplayScaleFactor
    }

    var displayedDeleteHandleDiameter: CGFloat {
        Self.deleteHandleDiameter / editingDisplayScaleFactor
    }

    var displayedDeleteHandleMargin: CGFloat {
        Self.deleteHandleMargin / editingDisplayScaleFactor
    }

    /// 편집 중인 도형에 이미지 선택 상태와 동일한 점선과 8개 방향별 크기 조절점을 표시합니다.
    func drawSelectionOutlineIfNeeded(in context: CGContext) {
        guard isPortalSelected else { return }
        let outlineInset = 0.5 / selectionDisplayScaleFactor
        let outlineRect = annotationOutlineRect.insetBy(dx: outlineInset, dy: outlineInset)
        context.saveGState()
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(displayedSelectionLineWidth)
        context.setLineDash(phase: 0, lengths: displayedSelectionDashLengths)
        context.stroke(outlineRect)
        // 점선 설정이 사각 조절점과 삭제 버튼 테두리에 전파되지 않도록 초기화합니다.
        context.setLineDash(phase: 0, lengths: [])
        drawResizeHandles(in: context)
        drawDeleteHandle(in: context)
        context.restoreGState()
    }

    /// 모서리 4개와 각 변 중앙 4개에 흰색 사각 조절점을 표시합니다.
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

    /// 선택 도형 왼쪽 상단에 삭제 버튼을 표시합니다.
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

    /// 현재 PDFView 배율을 선택 라인과 조절점 크기에 반영합니다.
    @discardableResult
    func updateEditingDisplayScaleFactor(_ scaleFactor: CGFloat) -> Bool {
        let normalizedScaleFactor = max(scaleFactor, 0.1)
        let normalizedEditingScaleFactor = max(scaleFactor, Self.minimumEditingDisplayScaleFactor)
        guard selectionDisplayScaleFactor != normalizedScaleFactor
                || editingDisplayScaleFactor != normalizedEditingScaleFactor else {
            return false
        }
        selectionDisplayScaleFactor = normalizedScaleFactor
        editingDisplayScaleFactor = normalizedEditingScaleFactor
        updatePresentationBounds()
        return true
    }

    func isTransformHandleHit(_ point: CGPoint, scaleFactor: CGFloat) -> Bool {
        resizeHandle(at: point, scaleFactor: scaleFactor) != nil
    }

    /// 화면 터치 위치와 가장 가까운 8방향 크기 조절점을 반환합니다.
    func resizeHandle(at point: CGPoint, scaleFactor: CGFloat) -> PortalPDFResizeHandle? {
        updateEditingDisplayScaleFactor(scaleFactor)
        let center = shapeBounds.center
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

    /// 선택 도형 왼쪽 상단 삭제 버튼의 터치 범위를 확인합니다.
    func isDeleteHandleHit(_ point: CGPoint, scaleFactor: CGFloat) -> Bool {
        updateEditingDisplayScaleFactor(scaleFactor)
        let center = pageDeleteHandleCenter
        let screenAdjustedRadius = 22 / max(scaleFactor, 0.01)
        let hitRadius = max(displayedDeleteHandleDiameter / 2, screenAdjustedRadius)
        return hypot(point.x - center.x, point.y - center.y) <= hitRadius
    }

    /// 회전 전 PDF 페이지 좌표계에서 8개 크기 조절점의 중심입니다.
    var unrotatedResizeHandleCenters: [PortalPDFResizeHandle: CGPoint] {
        let outlineRect = annotationOutlineRect
        return [
            .topLeft: CGPoint(x: outlineRect.minX, y: outlineRect.maxY),
            .topCenter: CGPoint(x: outlineRect.midX, y: outlineRect.maxY),
            .topRight: CGPoint(x: outlineRect.maxX, y: outlineRect.maxY),
            .middleLeft: CGPoint(x: outlineRect.minX, y: outlineRect.midY),
            .middleRight: CGPoint(x: outlineRect.maxX, y: outlineRect.midY),
            .bottomLeft: CGPoint(x: outlineRect.minX, y: outlineRect.minY),
            .bottomCenter: CGPoint(x: outlineRect.midX, y: outlineRect.minY),
            .bottomRight: CGPoint(x: outlineRect.maxX, y: outlineRect.minY),
        ]
    }

    /// 회전 전 PDF 페이지 좌표계의 왼쪽 상단 삭제 버튼 중심입니다.
    var unrotatedDeleteHandleCenter: CGPoint {
        let outlineRect = annotationOutlineRect
        let offset = displayedDeleteHandleDiameter / 2 + displayedDeleteHandleMargin
        return CGPoint(x: outlineRect.minX - offset, y: outlineRect.maxY + offset)
    }

    /// 현재 회전 각도를 반영한 PDF 페이지 좌표계의 왼쪽 상단 삭제 버튼 중심입니다.
    var pageDeleteHandleCenter: CGPoint {
        let center = CGPoint(x: shapeBounds.midX, y: shapeBounds.midY)
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

    /// 도형 편집이 활성화되었음을 안내하는 전체 주석 영역입니다.
    var annotationOutlineRect: CGRect {
        shapeBounds
    }

    func constrainedEditingBounds(_ candidate: CGRect, in container: CGRect) -> CGRect {
        Self.constrainedContentBounds(candidate, rotation: rotationAngle, in: container)
    }

    func constrainToPageIfNeeded() {
        guard let page else { return }
        shapeBounds = constrainedEditingBounds(shapeBounds, in: page.bounds(for: .cropBox))
    }

    func updatePresentationBounds() {
        bounds = Self.presentationBounds(for: shapeBounds, rotation: rotationAngle)
    }

    static func presentationBounds(for contentBounds: CGRect, rotation: CGFloat) -> CGRect {
        let outlineRect = contentBounds
        let resizePadding = resizeHandleSide / minimumEditingDisplayScaleFactor / 2
        let resizeBounds = outlineRect.insetBy(dx: -resizePadding, dy: -resizePadding)
        let reservedDeleteDiameter = deleteHandleDiameter / minimumEditingDisplayScaleFactor
        let reservedDeleteMargin = deleteHandleMargin / minimumEditingDisplayScaleFactor
        let deleteHandleOffset = reservedDeleteDiameter / 2 + reservedDeleteMargin
        let deleteHandleCenter = CGPoint(
            x: outlineRect.minX - deleteHandleOffset,
            y: outlineRect.maxY + deleteHandleOffset
        )
        let deleteHandleRect = CGRect(
            x: deleteHandleCenter.x - reservedDeleteDiameter / 2,
            y: deleteHandleCenter.y - reservedDeleteDiameter / 2,
            width: reservedDeleteDiameter,
            height: reservedDeleteDiameter
        )
        return resizeBounds
            .union(deleteHandleRect)
            .insetBy(dx: -clippingSafetyMargin, dy: -clippingSafetyMargin)
            .rotatedBoundingBox(around: contentBounds.center, by: rotation)
    }

    static func constrainedContentBounds(_ candidate: CGRect, rotation: CGFloat, in container: CGRect) -> CGRect {
        var adjusted = candidate
        let visibleBounds = presentationBounds(for: adjusted, rotation: rotation)
        let fittingScale = min(1, container.width / visibleBounds.width, container.height / visibleBounds.height)
        if fittingScale < 1 {
            adjusted = adjusted.scaled(around: adjusted.center, by: fittingScale)
        }
        let constrainedVisibleBounds = presentationBounds(for: adjusted, rotation: rotation)
        let dx = min(max(container.minX - constrainedVisibleBounds.minX, 0), container.maxX - constrainedVisibleBounds.maxX)
        let dy = min(max(container.minY - constrainedVisibleBounds.minY, 0), container.maxY - constrainedVisibleBounds.maxY)
        return adjusted.offsetBy(dx: dx, dy: dy)
    }
}

/**
 PDF 페이지 위에 사용자가 선택한 이미지를 그리는 Stamp Annotation 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalPDFPreviewView``
 */
