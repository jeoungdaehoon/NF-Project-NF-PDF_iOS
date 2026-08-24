//
// PortalPDFAnnotationCore.swift
// NF
//
// Shared annotation transformation and hit-testing contracts.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

/// 선택 박스의 모서리 4개와 변 중앙 4개 크기 조절점을 공통으로 나타냅니다.
enum PortalPDFResizeHandle: CaseIterable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight
}

protocol PortalPDFTransformableAnnotation: AnyObject {
    var bounds: CGRect { get set }
    /// 사용자가 이동·확대·축소하는 본문 영역입니다. PDFKit 클리핑 방지용 외곽 bounds와 분리할 수 있습니다.
    var editingBounds: CGRect { get set }
    var page: PDFPage? { get }
    var isPortalSelected: Bool { get set }
    var rotationAngle: CGFloat { get set }
    func constrainedEditingBounds(_ candidate: CGRect, in container: CGRect) -> CGRect
    func isTransformHandleHit(_ point: CGPoint, scaleFactor: CGFloat) -> Bool
}

extension PortalPDFTransformableAnnotation {
    /// 별도 구현이 없는 Annotation은 본문 영역과 PDFKit bounds를 동일하게 사용합니다.
    var editingBounds: CGRect {
        get { bounds }
        set { bounds = newValue }
    }

    /// Annotation 본문과 편집 UI가 페이지 바깥으로 잘리지 않도록 이동·확대 결과를 제한합니다.
    func constrainedEditingBounds(_ candidate: CGRect, in container: CGRect) -> CGRect {
        candidate.clampedInside(container)
    }

    /// 화면 확대 배율을 고려해 편집 본문 터치 영역을 확장합니다.
    func editingHitBounds(scaleFactor: CGFloat) -> CGRect {
        editingBounds.insetBy(dx: -18 / max(scaleFactor, 0.01), dy: -18 / max(scaleFactor, 0.01))
    }
}

/// 점선·편집 아이콘까지 포함한 PDFAnnotation bounds가 아닌 실제 편집 본문으로 대상을 찾습니다.
enum PortalPDFEditableAnnotationHitTesting {
    /// 이미지·박스·텍스트 편집 모드에서 터치한 최상단 객체를 실제 본문 영역 기준으로 반환합니다.
    static func topmostSelectableObject(
        in annotations: [PDFAnnotation],
        at point: CGPoint,
        scaleFactor: CGFloat
    ) -> PDFAnnotation? {
        let candidates = annotations.reversed().filter {
            $0 is PortalPDFImageAnnotation
                || $0 is PortalPDFShapeAnnotation
                || $0 is PortalPDFTextAnnotation
        }
        if let exactMatch = candidates.first(where: { containsSelectableContent($0, point: point, padding: 0) }) {
            return exactMatch
        }
        let touchPadding = 8 / max(scaleFactor, 0.01)
        return candidates.first {
            containsSelectableContent($0, point: point, padding: touchPadding)
        }
    }

    static func topmostAnnotation(
        in annotations: [PDFAnnotation],
        at point: CGPoint,
        scaleFactor: CGFloat
    ) -> PDFAnnotation? {
        let candidates = annotations.reversed().filter {
            $0 is PortalPDFImageAnnotation || $0 is PortalPDFShapeAnnotation
        }
        // 가까운 다른 이미지의 확장 터치 영역보다 실제로 누른 이미지 본문을 항상 우선합니다.
        if let exactMatch = candidates.first(where: { containsEditingContent($0, point: point, padding: 0) }) {
            return exactMatch
        }
        let touchPadding = 8 / max(scaleFactor, 0.01)
        return candidates.first {
            containsEditingContent($0, point: point, padding: touchPadding)
        }
    }

    private static func containsSelectableContent(
        _ annotation: PDFAnnotation,
        point: CGPoint,
        padding: CGFloat
    ) -> Bool {
        if let textAnnotation = annotation as? PortalPDFTextAnnotation {
            return textAnnotation.editingBounds
                .insetBy(dx: -padding, dy: -padding)
                .contains(point)
        }
        return containsEditingContent(annotation, point: point, padding: padding)
    }

    static func containsEditingContent(
        _ annotation: PDFAnnotation,
        point: CGPoint,
        padding: CGFloat
    ) -> Bool {
        let editingBounds: CGRect
        let rotationAngle: CGFloat
        if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
            editingBounds = imageAnnotation.editingBounds
            rotationAngle = imageAnnotation.rotationAngle
        } else if let shapeAnnotation = annotation as? PortalPDFShapeAnnotation {
            editingBounds = shapeAnnotation.editingBounds
            rotationAngle = shapeAnnotation.rotationAngle
        } else {
            return false
        }

        let center = editingBounds.center
        let offsetX = point.x - center.x
        let offsetY = point.y - center.y
        let cosine = cos(rotationAngle)
        let sine = sin(rotationAngle)
        // 회전된 화면 좌표를 회전 전 편집 본문 좌표로 되돌려 판정합니다.
        let unrotatedPoint = CGPoint(
            x: center.x + offsetX * cosine + offsetY * sine,
            y: center.y - offsetX * sine + offsetY * cosine
        )
        return editingBounds.insetBy(dx: -padding, dy: -padding).contains(unrotatedPoint)
    }
}

/// 압력값이 달라져도 구간 경계 없이 한 번에 채울 수 있는 연속 획 외곽선을 생성합니다.
