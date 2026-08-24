//
// PortalPDFDocumentPersistence.swift
// NF
//
// PDF annotation persistence, decoding helpers, and shared geometry/color utilities.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

/// PDFKit Annotation 객체 수를 제한하도록 연속 Ink를 다중 경로 묶음으로 정규화합니다.
/// 화면 표시는 Core Animation 벡터 오버레이가 담당하므로 Annotation bounds를 기준으로 나누지 않습니다.
enum PortalPDFStandardInkCompactor {
    static let maximumPathsPerAnnotation = 128

    private struct PagePath {
        let path: UIBezierPath
        let bounds: CGRect
    }

    static func compactedAnnotations(
        from annotations: [PDFAnnotation],
        minimumRunLength: Int = 2
    ) -> [PDFAnnotation] {
        var result: [PDFAnnotation] = []
        var inkRun: [PDFAnnotation] = []

        func flushInkRun() {
            guard !inkRun.isEmpty else { return }
            let requiresOversizedSplit = inkRun.contains { annotation in
                isOversizedInk(annotation)
            }
            guard inkRun.count >= minimumRunLength || requiresOversizedSplit else {
                result.append(contentsOf: inkRun)
                inkRun.removeAll(keepingCapacity: true)
                return
            }
            let compacted = compactedAnnotations(fromInkRun: inkRun)
            if hasEquivalentGrouping(inkRun, compacted) {
                result.append(contentsOf: inkRun)
            } else {
                result.append(contentsOf: compacted)
            }
            inkRun.removeAll(keepingCapacity: true)
        }

        for annotation in annotations {
            guard isCompactableInk(annotation) else {
                flushInkRun()
                result.append(annotation)
                continue
            }
            if let first = inkRun.first, !hasMatchingStyle(annotation, first) {
                flushInkRun()
            }
            inkRun.append(annotation)
        }
        flushInkRun()
        return result
    }

    static func compactPageIfNeeded(_ page: PDFPage, minimumRunLength: Int) -> Bool {
        let annotations = page.annotations
        let compacted = compactedAnnotations(
            from: annotations,
            minimumRunLength: minimumRunLength
        )
        guard didRewrite(annotations, as: compacted) else { return false }
        annotations.forEach { page.removeAnnotation($0) }
        compacted.forEach { page.addAnnotation($0) }
        return true
    }

    static func didRewrite(_ original: [PDFAnnotation], as optimized: [PDFAnnotation]) -> Bool {
        original.count != optimized.count
            || zip(original, optimized).contains(where: { $0 !== $1 })
    }

    private static func hasEquivalentGrouping(
        _ original: [PDFAnnotation],
        _ optimized: [PDFAnnotation]
    ) -> Bool {
        guard original.count == optimized.count else { return false }
        return zip(original, optimized).allSatisfy { originalAnnotation, optimizedAnnotation in
            let originalPathCount = originalAnnotation.paths?.count ?? 0
            let optimizedPathCount = optimizedAnnotation.paths?.count ?? 0
            let originalBounds = originalAnnotation.bounds
            let optimizedBounds = optimizedAnnotation.bounds
            return originalPathCount == optimizedPathCount
                && abs(originalBounds.minX - optimizedBounds.minX) < 0.01
                && abs(originalBounds.minY - optimizedBounds.minY) < 0.01
                && abs(originalBounds.width - optimizedBounds.width) < 0.01
                && abs(originalBounds.height - optimizedBounds.height) < 0.01
        }
    }

    private static func isCompactableInk(_ annotation: PDFAnnotation) -> Bool {
        annotation.isPortalInkAnnotation && !(annotation.paths?.isEmpty ?? true)
    }

    private static func isOversizedInk(_ annotation: PDFAnnotation) -> Bool {
        guard let paths = annotation.paths, paths.count > 1 else { return false }
        return paths.count > maximumPathsPerAnnotation
    }

    private static func hasMatchingStyle(_ lhs: PDFAnnotation, _ rhs: PDFAnnotation) -> Bool {
        let lhsBorder = lhs.border
        let rhsBorder = rhs.border
        return lhs.color.isEqual(rhs.color)
            && abs((lhsBorder?.lineWidth ?? 1) - (rhsBorder?.lineWidth ?? 1)) < 0.001
            && lhsBorder?.style == rhsBorder?.style
            && lhsBorder?.dashPattern as? [CGFloat] == rhsBorder?.dashPattern as? [CGFloat]
            && lhs.contents == rhs.contents
            && lhs.userName == rhs.userName
            && lhs.shouldDisplay == rhs.shouldDisplay
            && lhs.shouldPrint == rhs.shouldPrint
    }

    private static func compactedAnnotations(fromInkRun annotations: [PDFAnnotation]) -> [PDFAnnotation] {
        guard let first = annotations.first else { return [] }
        let lineWidth = first.border?.lineWidth ?? 1
        let padding = max(10, lineWidth * 2)
        let pagePaths = annotations.flatMap { annotation -> [PagePath] in
            annotation.paths?.map { path in
                let pagePath = path.translatedBy(
                    dx: annotation.bounds.minX,
                    dy: annotation.bounds.minY
                )
                return PagePath(
                    path: pagePath,
                    bounds: pagePath.bounds.insetBy(dx: -padding, dy: -padding)
                )
            } ?? []
        }
        guard !pagePaths.isEmpty else { return annotations }

        var chunks: [[PagePath]] = []
        var currentChunk: [PagePath] = []
        var currentBounds = CGRect.null

        func flushChunk() {
            guard !currentChunk.isEmpty else { return }
            chunks.append(currentChunk)
            currentChunk.removeAll(keepingCapacity: true)
            currentBounds = .null
        }

        for pagePath in pagePaths {
            let exceedsPathLimit = currentChunk.count >= maximumPathsPerAnnotation
            if exceedsPathLimit {
                flushChunk()
            }
            currentChunk.append(pagePath)
            currentBounds = currentBounds.isNull
                ? pagePath.bounds
                : currentBounds.union(pagePath.bounds)
        }
        flushChunk()

        return chunks.compactMap { chunk in
            compactedAnnotation(from: chunk, matching: first)
        }
    }

    private static func compactedAnnotation(
        from pagePaths: [PagePath],
        matching source: PDFAnnotation
    ) -> PDFAnnotation? {
        guard let firstPath = pagePaths.first else { return nil }
        let groupedBounds = pagePaths.dropFirst().reduce(firstPath.bounds) { partial, pagePath in
            partial.union(pagePath.bounds)
        }
        let grouped = PDFAnnotation(bounds: groupedBounds, forType: .ink, withProperties: nil)
        grouped.color = source.color
        grouped.border = source.border?.copy() as? PDFBorder
        grouped.contents = source.contents
        grouped.userName = source.userName
        grouped.shouldDisplay = source.shouldDisplay
        grouped.shouldPrint = source.shouldPrint

        for pagePath in pagePaths {
            grouped.add(pagePath.path.translatedBy(
                dx: -groupedBounds.minX,
                dy: -groupedBounds.minY
            ))
        }
        return grouped.paths?.isEmpty == false ? grouped : nil
    }
}

/// 앱 화면에서 Ink와 편집 이미지를 PDFKit Annotation 레이어 대신 오버레이로 표시할 때
/// 저장용 Annotation의 원래 표시 플래그를 안전하게 관리합니다.
enum PortalPDFInkDisplaySuppression {
    private static let annotations = NSHashTable<PDFAnnotation>.weakObjects()

    static func suppress(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            suppress(on: page)
        }
    }

    static func suppress(on page: PDFPage) {
        page.annotations.forEach { annotation in
            guard isOverlayRenderable(annotation) else { return }
            if annotation.shouldDisplay {
                annotations.add(annotation)
            }
            guard annotations.contains(annotation) else { return }
            annotation.shouldDisplay = false
            if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                // shouldDisplay=false만으로는 PDFKit이 이미지 Annotation용 효과 레이어를
                // 만들지 않는 것이 보장되지 않습니다. 실제 화면은 CGImage 오버레이가
                // 담당하므로 PDFKit이 참조하는 영역도 비워 고배율 backing store를 막습니다.
                imageAnnotation.bounds = .zero
            }
        }
    }

    static func isSuppressed(_ annotation: PDFAnnotation) -> Bool {
        annotations.contains(annotation)
    }

    static func restore(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            page.annotations.forEach { annotation in
                guard annotations.contains(annotation) else { return }
                annotations.remove(annotation)
                if let imageAnnotation = annotation as? PortalPDFImageAnnotation {
                    imageAnnotation.updatePresentationBounds()
                }
                annotation.shouldDisplay = true
            }
        }
    }

    static func isOverlayRenderable(_ annotation: PDFAnnotation) -> Bool {
        annotation.isPortalInkAnnotation
            || PortalPDFPressureInkAnnotation.isPressureInk(annotation)
            || annotation is PortalPDFImageAnnotation
    }
}

extension PDFDocument {
    /// 저장 PDF에 편집용 점선 박스가 찍히지 않도록 모든 이미지 Annotation 선택 상태를 해제합니다.
    func clearPortalImageAnnotationSelection() {
        for pageIndex in 0..<pageCount {
            page(at: pageIndex)?.annotations.compactMap { $0 as? PortalPDFImageAnnotation }.forEach { annotation in
                annotation.isPortalSelected = false
            }
            page(at: pageIndex)?.annotations.compactMap { $0 as? PortalPDFShapeAnnotation }.forEach { annotation in
                annotation.isPortalSelected = false
            }
        }
    }

    /// 이미지 주석 같은 커스텀 Annotation도 저장본에 포함되도록 각 페이지를 PDF로 다시 렌더링합니다.
    func portalFlattenedDataRepresentation() -> Data? {
        guard pageCount > 0 else { return nil }
        PortalPDFInkDisplaySuppression.restore(in: self)
        defer { PortalPDFInkDisplaySuppression.suppress(in: self) }
        let outputData = NSMutableData()
        UIGraphicsBeginPDFContextToData(outputData, .zero, nil)
        for pageIndex in 0..<pageCount {
            guard let page = page(at: pageIndex) else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            UIGraphicsBeginPDFPageWithInfo(pageBounds, nil)
            guard let context = UIGraphicsGetCurrentContext() else { continue }
            context.saveGState()
            context.translateBy(x: 0, y: pageBounds.height)
            context.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        UIGraphicsEndPDFContext()
        return outputData as Data
    }

    /// 커스텀 이미지·도형·텍스트를 다시 편집할 수 있도록 메타데이터를 갱신한 원본 PDF를 반환합니다.
    func portalEditableDataRepresentation() -> Data? {
        PortalPDFInkDisplaySuppression.restore(in: self)
        defer { PortalPDFInkDisplaySuppression.suppress(in: self) }
        for pageIndex in 0..<pageCount {
            guard let page = page(at: pageIndex) else { continue }
            let annotations = page.annotations
            annotations.compactMap { $0 as? PortalPDFImageAnnotation }
                .forEach { $0.prepareForPersistence() }
            annotations.compactMap { $0 as? PortalPDFTextAnnotation }
                .forEach { $0.prepareForPersistence() }

            // 기존 V1/V2 JSON 압력 획은 다음 저장 때 V3 바이너리 포맷으로 한 번 전환합니다.
            // 각 획을 그 자리에서 교체해 이미지·텍스트와의 쌓임 순서를 바꾸지 않습니다.
            let convertedAnnotations = annotations.map { annotation -> PDFAnnotation in
                guard PortalPDFPressureInkAnnotation.isPressureInk(annotation),
                      !PortalPDFPressureInkAnnotation.hasCompactMetadata(annotation),
                      let compacted = PortalPDFPressureInkAnnotation.compactedAnnotations(
                        from: [annotation]
                      ).first else {
                    return annotation
                }
                return compacted
            }
            let optimizedAnnotations = PortalPDFStandardInkCompactor.compactedAnnotations(
                from: convertedAnnotations
            )
            let didOptimize = PortalPDFStandardInkCompactor.didRewrite(
                annotations,
                as: optimizedAnnotations
            )
            guard didOptimize else {
                continue
            }
            annotations.forEach { page.removeAnnotation($0) }
            optimizedAnnotations.forEach { page.addAnnotation($0) }
        }
        return dataRepresentation()
    }

    /// 저장된 Stamp 메타데이터를 앱의 선택·이동 가능한 이미지·도형·텍스트 Annotation으로 복원합니다.
    @discardableResult
    func restorePortalEditableAnnotations() -> Bool {
        var didOptimizeInk = false
        for pageIndex in 0..<pageCount {
            guard let page = page(at: pageIndex) else { continue }
            let annotations = page.annotations
            let restoredAnnotations = annotations.map { annotation -> PDFAnnotation in
                PortalPDFImageAnnotation.restored(from: annotation)
                    ?? PortalPDFShapeAnnotation.restored(from: annotation)
                    ?? PortalPDFTextAnnotation.restored(from: annotation)
                    ?? annotation
            }
            let pressureAnnotations = restoredAnnotations.filter {
                PortalPDFPressureInkAnnotation.isPressureInk($0)
            }
            var optimizedAnnotations = restoredAnnotations
            if pressureAnnotations.count > 1 {
                let compacted = PortalPDFPressureInkAnnotation.compactedAnnotations(
                    from: pressureAnnotations
                )
                if !compacted.isEmpty, compacted.count < pressureAnnotations.count {
                    optimizedAnnotations.removeAll {
                        PortalPDFPressureInkAnnotation.isPressureInk($0)
                    }
                    optimizedAnnotations.append(contentsOf: compacted)
                    didOptimizeInk = true
                }
            }
            let standardInkCompacted = PortalPDFStandardInkCompactor.compactedAnnotations(
                from: optimizedAnnotations
            )
            if PortalPDFStandardInkCompactor.didRewrite(
                optimizedAnnotations,
                as: standardInkCompacted
            ) {
                optimizedAnnotations = standardInkCompacted
                didOptimizeInk = true
            }
            let didReplaceEditableAnnotation = zip(annotations, restoredAnnotations).contains { $0 !== $1 }
            guard didReplaceEditableAnnotation || optimizedAnnotations.count != annotations.count else { continue }
            annotations.forEach { page.removeAnnotation($0) }
            optimizedAnnotations.forEach { page.addAnnotation($0) }
        }
        return didOptimizeInk
    }
}

extension UIColor {
    var portalRGBA: [Double] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return [0, 0, 0, 1]
        }
        return [Double(red), Double(green), Double(blue), Double(alpha)]
    }

    static func portalColor(rgba: [Double]) -> UIColor? {
        guard rgba.count == 4 else { return nil }
        return UIColor(
            red: CGFloat(rgba[0]),
            green: CGFloat(rgba[1]),
            blue: CGFloat(rgba[2]),
            alpha: CGFloat(rgba[3])
        )
    }
}

struct PortalPDFAnnotationRaster: @unchecked Sendable {
    /// 백그라운드에서 방향 보정·디코드를 마친 편집용 CGImage 입니다.
    let cgImage: CGImage
}

extension UIImage {
    /// PDF 편집에 필요한 해상도로 축소·방향 보정·즉시 디코딩한 래스터를 만듭니다.
    nonisolated static func pdfAnnotationRaster(from data: Data) -> PortalPDFAnnotationRaster? {
        // PDF 화면의 일반적인 2배 해상도를 넘는 원본은 편집 체감 품질에 이득이 거의 없고,
        // 첫 Canvas/PDFKit 렌더링 시 큰 텍스처 업로드 지연만 만들기 때문에 1,024px로 제한합니다.
        let maximumPixelDimension = 1_024
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return PortalPDFAnnotationRaster(cgImage: cgImage)
    }
}

extension CGRect {
    /// Rect 중심을 기준으로 회전했을 때 모든 모서리를 포함하는 축 정렬 외곽 영역입니다.
    func rotatedBoundingBox(around center: CGPoint, by angle: CGFloat) -> CGRect {
        let cosine = cos(angle)
        let sine = sin(angle)
        let rotatedPoints = [
            CGPoint(x: minX, y: minY),
            CGPoint(x: minX, y: maxY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY)
        ].map { point in
            let x = point.x - center.x
            let y = point.y - center.y
            return CGPoint(
                x: center.x + x * cosine - y * sine,
                y: center.y + x * sine + y * cosine
            )
        }
        guard let first = rotatedPoints.first else { return self }
        return rotatedPoints.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    /// 중심을 유지하며 Rect 전체를 비율에 맞춰 확대·축소합니다.
    func scaled(around center: CGPoint, by scale: CGFloat) -> CGRect {
        CGRect(
            x: center.x - width * scale / 2,
            y: center.y - height * scale / 2,
            width: width * scale,
            height: height * scale
        )
    }

    /// Rect 중앙점입니다.
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    /// 대상 Rect가 기준 Rect 밖으로 빠지지 않도록 원래 크기를 유지하며 위치를 보정합니다.
    func clampedInside(_ container: CGRect) -> CGRect {
        guard width <= container.width, height <= container.height else { return intersection(container) }
        let clampedX = min(max(minX, container.minX), container.maxX - width)
        let clampedY = min(max(minY, container.minY), container.maxY - height)
        return CGRect(x: clampedX, y: clampedY, width: width, height: height)
    }
}

extension Array where Element == CGRect {
    /// 여러 압력 획 경로를 포함하는 하나의 Annotation 렌더 영역을 계산합니다.
    var unionRect: CGRect? {
        guard let first else { return nil }
        return dropFirst().reduce(first) { $0.union($1) }
    }
}

extension CGSize {
    /// 원본 비율을 유지하면서 지정한 최대 크기 안에 들어가는 표시 크기를 계산합니다.
    func fitted(in maxSize: CGSize, allowsUpscaling: Bool = false) -> CGSize {
        guard width > 0, height > 0 else { return .zero }
        let fittedScale = min(maxSize.width / width, maxSize.height / height)
        let scale = allowsUpscaling ? fittedScale : min(fittedScale, 1.0)
        return CGSize(width: width * scale, height: height * scale)
    }
}

extension UIBezierPath {
    /// PDF Ink Annotation을 입력점 안정화와 연속 3차 곡선으로 재구성해 한 획처럼 부드럽게 표시합니다.
    func smoothedForPDFInk(strokeSmoothingStrength: CGFloat = 0) -> UIBezierPath {
        let smoothedPath = UIBezierPath()
        smoothedPath.lineCapStyle = .round
        smoothedPath.lineJoinStyle = .round
        smoothedPath.flatness = 0.4
        // 주변 입력점을 함께 반영한 안정화 좌표를 사용해 손떨림으로 생기는 짧은
        // 방향 변화를 먼저 제거한 뒤 하나의 연속 곡선으로 재구성합니다.
        let points = cgPath.collectedPoints
            .terminalFlickStabilized(strength: strokeSmoothingStrength)
            .weightedMovingAverage(radius: 3)
        guard let firstPoint = points.first else { return self }
        smoothedPath.move(to: firstPoint)
        guard points.count > 2 else {
            points.dropFirst().forEach { smoothedPath.addLine(to: $0) }
            return smoothedPath
        }
        // Catmull-Rom 좌표를 3차 Bezier 제어점으로 변환해 각 구간의 접선이
        // 끊기지 않는 단일 경로를 만듭니다. 계수를 1/6보다 낮춰 필기 모서리의
        // 과도한 튀어나옴은 막으면서 원과 긴 선을 자연스럽게 연결합니다.
        let controlScale: CGFloat = 0.14
        for index in 0..<(points.count - 1) {
            let previous = points[max(0, index - 1)]
            let start = points[index]
            let end = points[index + 1]
            let following = points[min(points.count - 1, index + 2)]
            let firstControl = CGPoint(
                x: start.x + ((end.x - previous.x) * controlScale),
                y: start.y + ((end.y - previous.y) * controlScale)
            )
            let secondControl = CGPoint(
                x: end.x - ((following.x - start.x) * controlScale),
                y: end.y - ((following.y - start.y) * controlScale)
            )
            smoothedPath.addCurve(to: end, controlPoint1: firstControl, controlPoint2: secondControl)
        }
        return smoothedPath
    }

    /// PDFAnnotation Bounds 내부 좌표로 경로를 변환하기 위해 지정한 거리만큼 전체 경로를 이동합니다.
    func translatedBy(dx: CGFloat, dy: CGFloat) -> UIBezierPath {
        let translatedPath = UIBezierPath(cgPath: cgPath)
        translatedPath.lineCapStyle = lineCapStyle
        translatedPath.lineJoinStyle = lineJoinStyle
        translatedPath.flatness = flatness
        translatedPath.apply(CGAffineTransform(translationX: dx, y: dy))
        return translatedPath
    }
}

extension Array where Element == CGPoint {
    /// 좌표 묶음을 포함하는 최소 Rect를 반환합니다.
    var boundingRect: CGRect? {
        guard let first else { return nil }
        return dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    /// 현재 좌표에 가까운 점일수록 큰 가중치를 적용해 획의 전체 형태를 유지하며 손떨림만 줄입니다.
    func weightedMovingAverage(radius: Int) -> [CGPoint] {
        guard count > 2, radius > 0 else { return self }
        return indices.map { index in
            // 시작점과 끝점은 손가락을 댄 위치와 뗀 위치가 달라지지 않도록 그대로 유지합니다.
            guard index != startIndex, index != self.index(before: endIndex) else { return self[index] }
            let lowerBound = Swift.max(startIndex, index - radius)
            let upperBound = Swift.min(self.index(before: endIndex), index + radius)
            var weightedX: CGFloat = 0
            var weightedY: CGFloat = 0
            var totalWeight: CGFloat = 0
            for sampleIndex in lowerBound...upperBound {
                let distance = abs(sampleIndex - index)
                let weight = CGFloat(radius + 1 - distance)
                weightedX += self[sampleIndex].x * weight
                weightedY += self[sampleIndex].y * weight
                totalWeight += weight
            }
            return CGPoint(x: weightedX / totalWeight, y: weightedY / totalWeight)
        }
    }

    /// 획 시작과 끝의 짧은 입력점 묶음이 내부 진행 방향에서 벗어난 경우 삐침을 선택적으로 완화합니다.
    func terminalFlickStabilized(strength: CGFloat) -> [CGPoint] {
        let normalizedStrength = Swift.min(2, Swift.max(0, strength))
        guard normalizedStrength > 0, count >= 3 else { return self }

        // 긴 획은 진행 방향에서 갑자기 벗어난 끝 꼬리를 먼저 접선 방향으로 되돌립니다.
        // 짧은 한글 획도 강도 차이가 보이도록 그 다음 시작·끝 입력을 안쪽에 점진적으로
        // 정착시킵니다. 이 단계는 방향 이탈 여부와 무관하게 작동하므로 100%에서 실제
        // 삐침 길이가 분명히 줄어듭니다.
        let stabilizedEnd = count >= 6
            ? stabilizingTerminalFlick(strength: normalizedStrength)
            : self
        let stabilizedStart = Array(stabilizedEnd.reversed())
        let directionallyStabilized = count >= 6
            ? Array(stabilizedStart.stabilizingTerminalFlick(strength: normalizedStrength).reversed())
            : Array(stabilizedStart.reversed())

        let settledEnd = directionallyStabilized.settlingTerminalSamples(strength: normalizedStrength)
        let settledStart = Array(settledEnd.reversed())
            .settlingTerminalSamples(strength: normalizedStrength)
        return Array(settledStart.reversed())
    }

    /// 마지막 입력점 묶음을 안쪽 기준점에 점진적으로 당겨 펜을 떼며 생기는 짧은 꼬리를 줄입니다.
    private func settlingTerminalSamples(strength: CGFloat) -> [CGPoint] {
        guard count >= 3 else { return self }

        // 낮은 값에서는 필기 원형을 유지하되 70% 이후부터 보정량을 빠르게 높입니다.
        // 100% 초과분은 최대 보정률과 적용되는 끝 구간 길이를 비례해서 추가합니다.
        let baseStrength = Swift.min(1, strength)
        let overdriveStrength = Swift.min(1, Swift.max(0, strength - 1))
        let effectiveStrength = pow(baseStrength, 1.15)
        let highStrengthProgress = Swift.min(1, Swift.max(0, (baseStrength - 0.65) / 0.35))
        let highStrengthBoost = highStrengthProgress
            * highStrengthProgress
            * (3 - 2 * highStrengthProgress)
        let isMaximumRemoval = strength >= 1.999
        let maximumCorrection = isMaximumRemoval
            ? CGFloat(1)
            : 0.58 + 0.36 * highStrengthBoost + 0.055 * overdriveStrength
        let baseTerminalPointCount = Swift.min(6, Swift.max(1, count / 6 + 1))
        let extraTerminalPointCount = Int((overdriveStrength * 3).rounded())
        let maximumNonOverlappingCount = Swift.max(1, (count - 1) / 2)
        let terminalPointCount = Swift.min(
            maximumNonOverlappingCount,
            baseTerminalPointCount + extraTerminalPointCount
        )
        let anchorIndex = count - terminalPointCount - 1
        guard anchorIndex >= 0 else { return self }

        let anchor = self[anchorIndex]
        var result = self
        for index in (anchorIndex + 1)..<count {
            let point = self[index]
            // 끝 구간 전체를 같은 비율로 압축해야 좌표가 다시 뒤로 꺾이지 않습니다.
            // 200%에서는 해당 구간을 기준점에 완전히 정착시켜 잔여 삐침을 없앱니다.
            let localCorrection = Swift.min(
                maximumCorrection,
                effectiveStrength * maximumCorrection
            )
            result[index] = CGPoint(
                x: point.x + (anchor.x - point.x) * localCorrection,
                y: point.y + (anchor.y - point.y) * localCorrection
            )
        }
        return result
    }

    /// 배열 마지막의 최대 네 점을 안정된 내부 접선 쪽으로 점진적으로 당깁니다.
    private func stabilizingTerminalFlick(strength: CGFloat) -> [CGPoint] {
        guard count >= 6 else { return self }

        let terminalPointCount = Swift.min(4, Swift.max(2, count / 5 + 1))
        let anchorIndex = count - terminalPointCount - 1
        guard anchorIndex >= 2 else { return self }

        // 마지막 꼬리의 영향을 받지 않는 내부 구간 여러 개를 평균해 기준 진행 방향을 계산합니다.
        let referenceStartIndex = Swift.max(0, anchorIndex - 4)
        var referenceDirection = CGVector.zero
        var stableSegmentLengths: [CGFloat] = []
        for index in referenceStartIndex..<anchorIndex {
            let start = self[index]
            let end = self[index + 1]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { continue }
            referenceDirection.dx += dx / length
            referenceDirection.dy += dy / length
            stableSegmentLengths.append(length)
        }
        let referenceLength = hypot(referenceDirection.dx, referenceDirection.dy)
        guard referenceLength > 0.001, !stableSegmentLengths.isEmpty else { return self }

        let unitX = referenceDirection.dx / referenceLength
        let unitY = referenceDirection.dy / referenceLength
        let averageStableLength = stableSegmentLengths.reduce(0, +) / CGFloat(stableSegmentLengths.count)
        let anchor = self[anchorIndex]
        var minimumDirectionCosine: CGFloat = 1
        var maximumLateralDistance: CGFloat = 0
        var terminalPathLength: CGFloat = 0

        for index in (anchorIndex + 1)..<count {
            let previous = self[index - 1]
            let point = self[index]
            let segmentX = point.x - previous.x
            let segmentY = point.y - previous.y
            let segmentLength = hypot(segmentX, segmentY)
            guard segmentLength > 0.001 else { continue }
            terminalPathLength += segmentLength
            minimumDirectionCosine = Swift.min(
                minimumDirectionCosine,
                (segmentX * unitX + segmentY * unitY) / segmentLength
            )
            let fromAnchorX = point.x - anchor.x
            let fromAnchorY = point.y - anchor.y
            maximumLateralDistance = Swift.max(
                maximumLateralDistance,
                abs(fromAnchorX * unitY - fromAnchorY * unitX)
            )
        }
        guard terminalPathLength > 0.001 else { return self }

        // 각도와 측면 이탈 중 더 큰 값을 사용합니다. 정상 진행 방향과 10도 이내인 끝은 유지합니다.
        let angleFactor = Swift.min(1, Swift.max(0, (0.985 - minimumDirectionCosine) / 0.85))
        let lateralFactor = Swift.min(
            1,
            Swift.max(0, maximumLateralDistance / Swift.max(averageStableLength * 1.35, 0.001))
        )
        let flickFactor = Swift.max(angleFactor, lateralFactor)
        guard flickFactor > 0.01 else { return self }

        let totalPathLength = indices.dropFirst().reduce(CGFloat.zero) { partial, index in
            let previous = self[index - 1]
            let point = self[index]
            return partial + hypot(point.x - previous.x, point.y - previous.y)
        }
        let terminalShare = terminalPathLength / Swift.max(totalPathLength, 0.001)
        // 획 전체에서 차지하는 비중이 큰 방향 전환은 의도한 모양일 수 있으므로 보정량을 낮춥니다.
        // 짧은 필기에서는 꼬리 구간의 상대 비율이 커도 실제 거리는 짧을 수 있으므로 35% 이하는
        // 최대 신뢰도로 처리합니다. 긴 방향 전환만 단계적으로 낮춰 시작·끝 완화 체감이 사라지지 않게 합니다.
        let shortTailConfidence = Swift.min(1, Swift.max(0.35, (0.68 - terminalShare) / 0.32))
        let correction = strength * flickFactor * shortTailConfidence
        guard correction > 0.001 else { return self }

        var result = self
        for index in (anchorIndex + 1)..<count {
            let point = self[index]
            let fromAnchorX = point.x - anchor.x
            let fromAnchorY = point.y - anchor.y
            let forwardDistance = Swift.max(0, fromAnchorX * unitX + fromAnchorY * unitY)
            let projectedPoint = CGPoint(
                x: anchor.x + unitX * forwardDistance,
                y: anchor.y + unitY * forwardDistance
            )
            let terminalProgress = CGFloat(index - anchorIndex) / CGFloat(terminalPointCount)
            // 안쪽 좌표는 약하게, 실제 끝점은 강하게 보정해 경로가 갑자기 꺾이지 않게 연결합니다.
            let localCorrection = Swift.min(1, correction * (0.45 + terminalProgress * 0.55))
            result[index] = CGPoint(
                x: point.x + (projectedPoint.x - point.x) * localCorrection,
                y: point.y + (projectedPoint.y - point.y) * localCorrection
            )
        }
        return result
    }
}

extension Array where Element == CGFloat {
    /// 압력 센서의 짧은 진동을 완화하되 획 시작과 끝의 실제 압력은 유지합니다.
    func weightedMovingAverage(radius: Int) -> [CGFloat] {
        guard count > 2, radius > 0 else { return self }
        return indices.map { index in
            guard index != startIndex, index != self.index(before: endIndex) else { return self[index] }
            let lowerBound = Swift.max(startIndex, index - radius)
            let upperBound = Swift.min(self.index(before: endIndex), index + radius)
            var weightedValue: CGFloat = 0
            var totalWeight: CGFloat = 0
            for sampleIndex in lowerBound...upperBound {
                let distance = abs(sampleIndex - index)
                let weight = CGFloat(radius + 1 - distance)
                weightedValue += self[sampleIndex] * weight
                totalWeight += weight
            }
            return weightedValue / totalWeight
        }
    }
}

extension CGPoint {
    /// 점과 선분 사이의 최단 거리를 계산합니다.
    func distance(toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return hypot(x - start.x, y - start.y) }
        let progress = min(1, max(0, ((x - start.x) * dx + (y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + dx * progress, y: start.y + dy * progress)
        return hypot(x - projection.x, y - projection.y)
    }
}

extension CGPath {
    /// UIBezierPath를 부드러운 PDF Ink 경로로 재구성하기 위해 경로에 포함된 주요 좌표를 수집합니다.
    var collectedPoints: [CGPoint] {
        var points: [CGPoint] = []
        applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.points[0])
            case .addQuadCurveToPoint:
                points.append(element.points[0])
                points.append(element.points[1])
            case .addCurveToPoint:
                points.append(element.points[0])
                points.append(element.points[1])
                points.append(element.points[2])
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        return points
    }
}

extension UIView {
    /// 현재 View와 모든 하위 View를 포함한 계층을 반환합니다.
    var recursiveSubviewsIncludingSelf: [UIView] {
        [self] + subviews.flatMap(\.recursiveSubviewsIncludingSelf)
    }

    /// PDFView 하위 View 계층에 포함된 UIScrollView 목록을 재귀적으로 찾습니다.
    var recursiveScrollViews: [UIScrollView] {
        let ownScrollView = self as? UIScrollView
        return (ownScrollView.map { [$0] } ?? []) + subviews.flatMap(\.recursiveScrollViews)
    }

    /// PDFView와 하위 View 계층에 연결된 모든 Gesture Recognizer를 재귀적으로 찾습니다.
    var allGestureRecognizers: [UIGestureRecognizer] {
        (gestureRecognizers ?? []) + subviews.flatMap(\.allGestureRecognizers)
    }
}

extension Data {
    /// PDF 파일 시그니처 `%PDF` 로 시작하는지 확인합니다.
    var startsWithPDFSignature: Bool {
        starts(with: [0x25, 0x50, 0x44, 0x46])
    }
}

extension PDFAnnotation {
    /// PDFKit이 Ink 타입을 `Ink` 또는 `/Ink`로 반환하는 환경을 모두 정규화합니다.
    var isPortalInkAnnotation: Bool {
        guard let type else { return false }
        let slashCharacterSet = CharacterSet(charactersIn: "/")
        let normalizedType = type.trimmingCharacters(in: slashCharacterSet)
        let normalizedInkType = PDFAnnotationSubtype.ink.rawValue
            .trimmingCharacters(in: slashCharacterSet)
        return normalizedType.caseInsensitiveCompare(normalizedInkType) == .orderedSame
    }
}

extension HTTPURLResponse {
    /// 서버 Content-Type Header가 PDF를 나타내는지 확인합니다.
    var isPDFContentType: Bool {
        (value(forHTTPHeaderField: "Content-Type") ?? "").localizedCaseInsensitiveContains("application/pdf")
    }
}

#Preview {
    PortalPDFPreviewView(item: PortalAttachmentPreviewItem(url: URL(string: "https://example.com/sample.pdf")!, cookieHeader: nil))
}
