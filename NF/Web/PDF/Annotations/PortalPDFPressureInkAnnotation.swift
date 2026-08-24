//
// PortalPDFPressureInkAnnotation.swift
// NF
//
// Variable-width stroke generation and pressure-sensitive ink annotation.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

enum PortalPDFVariableWidthStroke {
    static func makePath(
        points: [CGPoint],
        pressures: [CGFloat],
        baseLineWidth: CGFloat
    ) -> UIBezierPath? {
        guard !points.isEmpty, points.count == pressures.count else { return nil }

        var filteredPoints: [CGPoint] = []
        var filteredPressures: [CGFloat] = []
        for (point, pressure) in zip(points, pressures) {
            if let previousPoint = filteredPoints.last,
               hypot(point.x - previousPoint.x, point.y - previousPoint.y) < 0.08 {
                filteredPoints[filteredPoints.count - 1] = point
                filteredPressures[filteredPressures.count - 1] = pressure
            } else {
                filteredPoints.append(point)
                filteredPressures.append(pressure)
            }
        }
        guard let firstPoint = filteredPoints.first else { return nil }

        let smoothedPoints = filteredPoints.weightedMovingAverage(radius: 2)
        // 압력 평균 구간을 조금 줄여 강약 변화가 실제 선 굵기에 더 빠르게 반영되게 합니다.
        let smoothedPressures = filteredPressures.weightedMovingAverage(radius: 4)
        let widths = continuousLineWidths(pressures: smoothedPressures, baseLineWidth: baseLineWidth)
        guard smoothedPoints.count > 1 else {
            let diameter = widths.first ?? max(0.3, baseLineWidth)
            return UIBezierPath(
                ovalIn: CGRect(
                    x: firstPoint.x - diameter / 2,
                    y: firstPoint.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
            )
        }

        // 좌우 외곽선을 하나의 큰 다각형으로 닫으면 작은 한글 곡선이나 되돌아오는 획에서
        // 외곽선이 서로 교차해 내부가 흰색으로 뚫릴 수 있습니다. 각 입력점을 원형 접점으로,
        // 인접 구간을 독립된 사다리꼴로 채워 중심 연결선이 어떤 방향에서도 끊기지 않게 합니다.
        let path = UIBezierPath()
        path.usesEvenOddFillRule = false
        for index in smoothedPoints.indices {
            let point = smoothedPoints[index]
            let radius = widths[index] / 2
            appendRoundJoin(center: point, radius: radius, to: path)

            guard index < smoothedPoints.count - 1 else { continue }
            let nextPoint = smoothedPoints[index + 1]
            let dx = nextPoint.x - point.x
            let dy = nextPoint.y - point.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { continue }

            let normalX = -dy / length
            let normalY = dx / length
            let nextRadius = widths[index + 1] / 2
            let connector = UIBezierPath()
            // 원형 접점과 동일한 양의 winding 방향으로 연결 면을 만듭니다.
            connector.move(to: CGPoint(
                x: point.x + normalX * radius,
                y: point.y + normalY * radius
            ))
            connector.addLine(to: CGPoint(
                x: point.x - normalX * radius,
                y: point.y - normalY * radius
            ))
            connector.addLine(to: CGPoint(
                x: nextPoint.x - normalX * nextRadius,
                y: nextPoint.y - normalY * nextRadius
            ))
            connector.addLine(to: CGPoint(
                x: nextPoint.x + normalX * nextRadius,
                y: nextPoint.y + normalY * nextRadius
            ))
            connector.close()
            path.append(connector)
        }
        return path
    }

    static func lineWidth(for pressure: CGFloat, baseLineWidth: CGFloat) -> CGFloat {
        let normalizedPressure = min(1, max(0, pressure))
        // 기존 0.45~1.70배보다 압력 대비 범위를 넓혀 강하게 누를 때 굵기 차이를 분명하게 합니다.
        return max(0.3, baseLineWidth * (0.42 + normalizedPressure * 1.58))
    }

    static func continuousLineWidths(
        pressures: [CGFloat],
        baseLineWidth: CGFloat
    ) -> [CGFloat] {
        guard !pressures.isEmpty else { return [] }
        let targets = pressures.map { lineWidth(for: $0, baseLineWidth: baseLineWidth) }
        let maximumStep = max(0.05, baseLineWidth * 0.075)
        var widths = targets

        // 압력 센서가 한 프레임에서 크게 바뀌어도 인접 좌표의 굵기는 조금씩만 변하게 합니다.
        for index in 1..<widths.count {
            widths[index] = widths[index - 1] + min(max(targets[index] - widths[index - 1], -maximumStep), maximumStep)
        }
        if widths.count > 1 {
            for index in stride(from: widths.count - 2, through: 0, by: -1) {
                widths[index] = widths[index + 1] + min(max(widths[index] - widths[index + 1], -maximumStep), maximumStep)
            }
        }
        return widths
    }

    /// 연결 면과 동일한 winding 방향의 원형 접점을 만들어 겹치는 구간이 투명하게 빠지지 않게 합니다.
    static func appendRoundJoin(center: CGPoint, radius: CGFloat, to path: UIBezierPath) {
        // 24개 직선으로 원을 근사하면 획마다 PDF 벡터 명령이 크게 늘어납니다.
        // UIKit의 타원 경로는 베지어 곡선으로 같은 원형 품질을 유지하면서 훨씬 적은 명령을 사용합니다.
        path.append(
            UIBezierPath(
                ovalIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        )
    }

}

/// 압력식 필기 한 획을 여러 Ink 조각이 아닌 하나의 연속 채움 경로로 렌더링합니다.
final class PortalPDFPressureInkAnnotation: PDFAnnotation {
    static let metadataPrefix = "NF_PRESSURE_INK_V1:"
    static let groupedMetadataPrefix = "NF_PRESSURE_INK_V2:"
    static let compactMetadataPrefix = "NF_PRESSURE_INK_V3:"

    struct Metadata: Codable {
        let points: [[Double]]
        let pressures: [Double]
        let baseLineWidth: Double
        let colorRGBA: [Double]?
    }

    struct GroupedMetadata: Codable {
        let strokes: [StoredStroke]
        let baseLineWidth: Double
        let colorRGBA: [Double]?
    }

    /// V3는 화면 품질에 영향이 없는 0.01pt 좌표·16비트 압력으로 메타데이터를 압축합니다.
    private struct CompactMetadata {
        let fragments: [StrokeFragment]
        let baseLineWidth: CGFloat
        let colorRGBA: [CGFloat]?
    }

    private struct CompactMetadataReader {
        let data: Data
        var offset: Int = 0

        mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let byteCount = MemoryLayout<T>.size
            guard offset + byteCount <= data.count else { return nil }
            let value: T = data.withUnsafeBytes { rawBuffer in
                rawBuffer.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            offset += byteCount
            return T(littleEndian: value)
        }
    }

    struct StoredStroke: Codable {
        let points: [[Double]]
        let pressures: [Double]
    }

    struct StrokeStyleKey: Hashable {
        let lineWidth: Int
        let rgba: [Int]
    }

    struct StrokeFragment {
        let points: [CGPoint]
        let pressures: [CGFloat]
    }

    enum StrokeErasureResult {
        case unchanged
        case updated
        case removed
    }

    fileprivate private(set) var strokeFragments: [StrokeFragment]
    fileprivate let baseLineWidth: CGFloat
    let strokeColor: UIColor
    var strokePaths: [UIBezierPath]
    private var strokePathBounds: [CGRect]
    var strokeFragmentCount: Int {
        strokeFragments.count
    }
    var renderedPathBounds: CGRect {
        strokePathBounds.unionRect ?? .zero
    }

    init(
        points: [CGPoint],
        pressures: [CGFloat],
        baseLineWidth: CGFloat,
        color: UIColor,
        renderedPath: UIBezierPath? = nil
    ) {
        self.strokeFragments = [StrokeFragment(points: points, pressures: pressures)]
        // 실시간 Overlay도 아래 경로 생성기에서 좌표·압력을 한 번 보정합니다.
        // 생성자에서 미리 다시 보정하면 펜을 떼는 순간 저장선만 이중 보정되어
        // 사용자가 보고 있던 곡선과 위치·굵기가 달라지므로 원본 샘플을 그대로 전달합니다.
        let path = renderedPath ?? Self.makeStrokePath(
            points: points,
            pressures: pressures,
            baseLineWidth: baseLineWidth
        ) ?? UIBezierPath()
        self.baseLineWidth = baseLineWidth
        self.strokeColor = color
        self.strokePaths = [path]
        self.strokePathBounds = [path.bounds]
        // PDFKit이 Stamp 외곽을 타일 단위로 자를 때 두꺼운 획의 끝부분이 사라지지 않도록
        // 실제 선 굵기와 안티앨리어싱을 포함한 충분한 여유 영역을 확보합니다.
        let drawingPadding = max(
            6,
            PortalPDFVariableWidthStroke.lineWidth(for: 1, baseLineWidth: baseLineWidth) / 2 + 3
        )
        super.init(
            bounds: path.bounds.insetBy(dx: -drawingPadding, dy: -drawingPadding),
            forType: .stamp,
            withProperties: nil
        )
        contents = Self.encodedMetadata(
            points: points,
            pressures: pressures,
            baseLineWidth: baseLineWidth,
            color: color
        )
        userName = "NF Pressure Ink"
        setValue(UUID().uuidString, forAnnotationKey: .name)
        shouldDisplay = true
        shouldPrint = true
    }

    /// 지우개로 나뉜 여러 구간을 PDF Annotation 하나로 묶어 렌더링합니다.
    init(
        fragments: [StrokeFragment],
        baseLineWidth: CGFloat,
        color: UIColor
    ) {
        let validFragments = fragments.filter {
            !$0.points.isEmpty && $0.points.count == $0.pressures.count
        }
        self.strokeFragments = validFragments
        self.baseLineWidth = baseLineWidth
        self.strokeColor = color
        let paths = validFragments.compactMap {
            Self.makeStrokePath(
                points: $0.points,
                pressures: $0.pressures,
                baseLineWidth: baseLineWidth
            )
        }
        self.strokePaths = paths
        self.strokePathBounds = paths.map(\.bounds)
        let pathBounds = strokePathBounds.unionRect ?? .zero
        let drawingPadding = max(
            6,
            PortalPDFVariableWidthStroke.lineWidth(for: 1, baseLineWidth: baseLineWidth) / 2 + 3
        )
        super.init(
            bounds: pathBounds.insetBy(dx: -drawingPadding, dy: -drawingPadding),
            forType: .stamp,
            withProperties: nil
        )
        contents = Self.encodedGroupedMetadata(
            fragments: validFragments,
            baseLineWidth: baseLineWidth,
            color: color
        )
        userName = "NF Pressure Ink"
        setValue(UUID().uuidString, forAnnotationKey: .name)
        shouldDisplay = true
        shouldPrint = true
    }

    /// 실시간 Overlay와 PDF 저장 주석이 공유하는 단일 압력선 경로 생성 진입점입니다.
    static func makeStrokePath(
        points: [CGPoint],
        pressures: [CGFloat],
        baseLineWidth: CGFloat
    ) -> UIBezierPath? {
        PortalPDFVariableWidthStroke.makePath(
            points: points,
            pressures: pressures,
            baseLineWidth: baseLineWidth
        )
    }

    /// 곡률과 압력 변화가 눈에 보이는 지점만 보존해 저장·렌더링할 표본 수를 줄입니다.
    /// 직선 구간의 중간 표본을 제거해도 폭 변화는 선형 보간되므로 필기 외형은 유지됩니다.
    static func optimizedStrokeFragment(
        points: [CGPoint],
        pressures: [CGFloat],
        baseLineWidth: CGFloat
    ) -> StrokeFragment {
        guard points.count > 2, points.count == pressures.count else {
            return StrokeFragment(points: points, pressures: pressures)
        }

        let geometryTolerance: CGFloat = 0.35
        let widthTolerance = max(0.08, baseLineWidth * 0.04)
        var retained = Set([0, points.count - 1])
        var pendingRanges = [(start: 0, end: points.count - 1)]

        while let range = pendingRanges.popLast(), range.end - range.start > 1 {
            let startPoint = points[range.start]
            let endPoint = points[range.end]
            let delta = CGPoint(x: endPoint.x - startPoint.x, y: endPoint.y - startPoint.y)
            let lengthSquared = delta.x * delta.x + delta.y * delta.y
            var largestError: CGFloat = 0
            var splitIndex: Int?

            for index in (range.start + 1)..<range.end {
                let point = points[index]
                let projection: CGFloat
                if lengthSquared > 0.0001 {
                    projection = min(
                        1,
                        max(
                            0,
                            ((point.x - startPoint.x) * delta.x + (point.y - startPoint.y) * delta.y)
                                / lengthSquared
                        )
                    )
                } else {
                    projection = 0
                }
                let projectedPoint = CGPoint(
                    x: startPoint.x + delta.x * projection,
                    y: startPoint.y + delta.y * projection
                )
                let geometryError = hypot(point.x - projectedPoint.x, point.y - projectedPoint.y)
                let expectedPressure = pressures[range.start]
                    + (pressures[range.end] - pressures[range.start]) * projection
                let widthError = abs(
                    PortalPDFVariableWidthStroke.lineWidth(
                        for: pressures[index],
                        baseLineWidth: baseLineWidth
                    ) - PortalPDFVariableWidthStroke.lineWidth(
                        for: expectedPressure,
                        baseLineWidth: baseLineWidth
                    )
                )
                let error = max(geometryError / geometryTolerance, widthError / widthTolerance)
                if error > largestError {
                    largestError = error
                    splitIndex = index
                }
            }

            guard largestError > 1, let splitIndex else { continue }
            retained.insert(splitIndex)
            pendingRanges.append((range.start, splitIndex))
            pendingRanges.append((splitIndex, range.end))
        }

        let indexes = retained.sorted()
        return StrokeFragment(
            points: indexes.map { points[$0] },
            pressures: indexes.map { pressures[$0] }
        )
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 지우개가 남긴 압력 획 조각을 기존 Annotation 객체에 반영합니다.
    /// 페이지에서 remove/add하지 않아 PDFKit 내부 Annotation·타일 캐시가 누적되지 않습니다.
    @discardableResult
    func replaceStrokeFragments(_ fragments: [StrokeFragment]) -> Bool {
        let validFragments = fragments.filter {
            !$0.points.isEmpty && $0.points.count == $0.pressures.count
        }
        guard !validFragments.isEmpty else { return false }
        let paths = validFragments.compactMap {
            Self.makeStrokePath(
                points: $0.points,
                pressures: $0.pressures,
                baseLineWidth: baseLineWidth
            )
        }
        guard let pathBounds = paths.map(\.bounds).unionRect else { return false }

        applyStrokeFragments(
            validFragments,
            paths: paths,
            pathBounds: pathBounds,
            updatesMetadata: true
        )
        return true
    }

    /// 지우개와 실제로 겹친 획 조각만 다시 계산하고 나머지 경로 객체는 그대로 재사용합니다.
    /// 드래그 중에는 대용량 JSON 메타데이터 생성을 미뤄 메인 스레드 입력 지연을 줄입니다.
    func eraseStrokeFragments(
        around centers: [CGPoint],
        eraserRadius: CGFloat
    ) -> StrokeErasureResult {
        guard !centers.isEmpty,
              strokeFragments.count == strokePaths.count,
              strokePaths.count == strokePathBounds.count else {
            return .unchanged
        }

        var updatedFragments: [StrokeFragment] = []
        var updatedPaths: [UIBezierPath] = []
        var updatedPathBounds: [CGRect] = []
        updatedFragments.reserveCapacity(strokeFragments.count)
        updatedPaths.reserveCapacity(strokePaths.count)
        updatedPathBounds.reserveCapacity(strokePathBounds.count)
        var didErase = false

        for index in strokeFragments.indices {
            let fragment = strokeFragments[index]
            let path = strokePaths[index]
            let pathBounds = strokePathBounds[index]
            let hitBounds = pathBounds.insetBy(dx: -eraserRadius, dy: -eraserRadius)
            let relevantCenters = centers.filter(hitBounds.contains)

            guard !relevantCenters.isEmpty else {
                updatedFragments.append(fragment)
                updatedPaths.append(path)
                updatedPathBounds.append(pathBounds)
                continue
            }

            var remainingFragments = [fragment]
            var fragmentDidErase = false
            for center in relevantCenters where !remainingFragments.isEmpty {
                remainingFragments = remainingFragments.flatMap { currentFragment in
                    guard let result = Self.fragmentsAfterErasing(
                        currentFragment,
                        around: center,
                        eraserRadius: eraserRadius,
                        baseLineWidth: baseLineWidth
                    ) else {
                        return [currentFragment]
                    }
                    fragmentDidErase = true
                    return result
                }
            }

            guard fragmentDidErase else {
                updatedFragments.append(fragment)
                updatedPaths.append(path)
                updatedPathBounds.append(pathBounds)
                continue
            }

            didErase = true
            for remainingFragment in remainingFragments {
                guard let remainingPath = Self.makeStrokePath(
                    points: remainingFragment.points,
                    pressures: remainingFragment.pressures,
                    baseLineWidth: baseLineWidth
                ) else { continue }
                updatedFragments.append(remainingFragment)
                updatedPaths.append(remainingPath)
                updatedPathBounds.append(remainingPath.bounds)
            }
        }

        guard didErase else { return .unchanged }
        guard let pathBounds = updatedPathBounds.unionRect else { return .removed }
        applyStrokeFragments(
            updatedFragments,
            paths: updatedPaths,
            pathBounds: pathBounds,
            updatesMetadata: false
        )
        return .updated
    }

    /// 지우개 입력이 끝난 뒤 현재 조각 정보를 저장 가능한 메타데이터로 한 번만 직렬화합니다.
    func prepareForPersistence() {
        contents = Self.encodedGroupedMetadata(
            fragments: strokeFragments,
            baseLineWidth: baseLineWidth,
            color: strokeColor
        )
    }

    private func applyStrokeFragments(
        _ fragments: [StrokeFragment],
        paths: [UIBezierPath],
        pathBounds: CGRect,
        updatesMetadata: Bool
    ) {
        strokeFragments = fragments
        strokePaths = paths
        strokePathBounds = paths.map(\.bounds)
        let drawingPadding = max(
            6,
            PortalPDFVariableWidthStroke.lineWidth(for: 1, baseLineWidth: baseLineWidth) / 2 + 3
        )
        bounds = pathBounds.insetBy(dx: -drawingPadding, dy: -drawingPadding)
        if updatesMetadata {
            prepareForPersistence()
        }
    }

    /// 올가미 그룹 이동 시 압력 획의 실제 좌표와 저장 메타데이터를 함께 이동합니다.
    func translateStroke(by delta: CGPoint) {
        let translatedFragments = strokeFragments.map { fragment in
            StrokeFragment(
                points: fragment.points.map {
                    CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
                },
                pressures: fragment.pressures
            )
        }
        _ = replaceStrokeFragments(translatedFragments)
    }

    /// 올가미 그룹 변형 시 압력 획 좌표와 저장 메타데이터를 함께 변형합니다.
    func transformStroke(scale: CGFloat, rotation: CGFloat, around center: CGPoint) {
        let cosine = cos(rotation)
        let sine = sin(rotation)
        let transformedFragments = strokeFragments.map { fragment in
            StrokeFragment(
                points: fragment.points.map { point in
                    let offsetX = (point.x - center.x) * scale
                    let offsetY = (point.y - center.y) * scale
                    return CGPoint(
                        x: center.x + offsetX * cosine - offsetY * sine,
                        y: center.y + offsetX * sine + offsetY * cosine
                    )
                },
                pressures: fragment.pressures
            )
        }
        _ = replaceStrokeFragments(transformedFragments)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(strokeColor.cgColor)
        let visibleBounds = context.boundingBoxOfClipPath
        for index in strokePaths.indices {
            guard visibleBounds.isNull
                    || visibleBounds.isInfinite
                    || strokePathBounds[index].intersects(visibleBounds) else {
                continue
            }
            let path = strokePaths[index]
            context.addPath(path.cgPath)
            context.drawPath(using: .fill)
        }
        context.restoreGState()
    }

    /// Annotation의 사각 Bounds가 아니라 실제 압력식 중심선과 지우개가 겹치는지 확인합니다.
    fileprivate func containsStroke(_ point: CGPoint, extraRadius: CGFloat) -> Bool {
        strokeFragments.contains {
            Self.containsStroke(
                point,
                points: $0.points,
                pressures: $0.pressures,
                baseLineWidth: baseLineWidth,
                extraRadius: extraRadius
            )
        }
    }

    /// 현재 메모리 객체와 PDF 저장 후 다시 생성된 일반 Stamp를 모두 압력식 획으로 판별합니다.
    static func isPressureInk(_ annotation: PDFAnnotation) -> Bool {
        annotation is PortalPDFPressureInkAnnotation
            || decodedCompactMetadata(from: annotation) != nil
            || decodedGroupedMetadata(from: annotation) != nil
            || decodedMetadata(from: annotation) != nil
    }

    /// 저장된 Annotation이 현재의 경량 V3 메타데이터를 이미 사용하는지 판별합니다.
    static func hasCompactMetadata(_ annotation: PDFAnnotation) -> Bool {
        annotation.contents?.hasPrefix(compactMetadataPrefix) == true
    }

    /// 재로딩된 일반 Stamp도 저장된 중심선 메타데이터를 사용해 정확한 지우개 충돌을 판정합니다.
    static func containsStroke(
        in annotation: PDFAnnotation,
        point: CGPoint,
        extraRadius: CGFloat
    ) -> Bool {
        if let pressureAnnotation = annotation as? PortalPDFPressureInkAnnotation {
            return pressureAnnotation.strokeFragments.contains {
                containsStroke(
                    point,
                    points: $0.points,
                    pressures: $0.pressures,
                    baseLineWidth: pressureAnnotation.baseLineWidth,
                    extraRadius: extraRadius
                )
            }
        }
        if let compactMetadata = decodedCompactMetadata(from: annotation) {
            return compactMetadata.fragments.contains {
                containsStroke(
                    point,
                    points: $0.points,
                    pressures: $0.pressures,
                    baseLineWidth: compactMetadata.baseLineWidth,
                    extraRadius: extraRadius
                )
            }
        }
        if let groupedMetadata = decodedGroupedMetadata(from: annotation) {
            return decodedFragments(from: groupedMetadata).contains {
                containsStroke(
                    point,
                    points: $0.points,
                    pressures: $0.pressures,
                    baseLineWidth: CGFloat(groupedMetadata.baseLineWidth),
                    extraRadius: extraRadius
                )
            }
        }
        guard let metadata = decodedMetadata(from: annotation) else { return false }
        let points = metadata.points.compactMap { coordinates -> CGPoint? in
            guard coordinates.count == 2 else { return nil }
            return CGPoint(x: coordinates[0], y: coordinates[1])
        }
        let pressures = metadata.pressures.map { CGFloat($0) }
        guard points.count == pressures.count else { return false }
        return containsStroke(
            point,
            points: points,
            pressures: pressures,
            baseLineWidth: CGFloat(metadata.baseLineWidth),
            extraRadius: extraRadius
        )
    }

    static func storedBaseLineWidth(in annotation: PDFAnnotation) -> CGFloat? {
        if let pressureAnnotation = annotation as? PortalPDFPressureInkAnnotation {
            return pressureAnnotation.baseLineWidth
        }
        if let compactMetadata = decodedCompactMetadata(from: annotation) {
            return compactMetadata.baseLineWidth
        }
        if let groupedMetadata = decodedGroupedMetadata(from: annotation) {
            return CGFloat(groupedMetadata.baseLineWidth)
        }
        return decodedMetadata(from: annotation).map { CGFloat($0.baseLineWidth) }
    }

    static func storedColor(in annotation: PDFAnnotation) -> UIColor {
        if let pressureAnnotation = annotation as? PortalPDFPressureInkAnnotation {
            return pressureAnnotation.strokeColor
        }
        if let components = decodedCompactMetadata(from: annotation)?.colorRGBA,
           components.count == 4 {
            return UIColor(
                red: components[0],
                green: components[1],
                blue: components[2],
                alpha: components[3]
            )
        }
        if let components = decodedGroupedMetadata(from: annotation)?.colorRGBA,
           components.count == 4 {
            return UIColor(
                red: CGFloat(components[0]),
                green: CGFloat(components[1]),
                blue: CGFloat(components[2]),
                alpha: CGFloat(components[3])
            )
        }
        if let components = decodedMetadata(from: annotation)?.colorRGBA,
           components.count == 4 {
            return UIColor(
                red: CGFloat(components[0]),
                green: CGFloat(components[1]),
                blue: CGFloat(components[2]),
                alpha: CGFloat(components[3])
            )
        }
        return annotation.color
    }

    /// 지우개 원과 겹친 압력식 중심선 구간만 잘라내고 남은 앞·뒤 획을 반환합니다.
    /// `nil`은 충돌하지 않음, 빈 배열은 획 전체가 지워졌음을 의미합니다.
    static func fragmentsAfterErasing(
        _ annotation: PDFAnnotation,
        around center: CGPoint,
        eraserRadius: CGFloat
    ) -> [StrokeFragment]? {
        fragmentsAfterErasing(
            annotation,
            around: [center],
            eraserRadius: eraserRadius
        )
    }

    /// 한 처리 프레임의 모든 지우개 좌표를 메모리에서 반영해 Annotation 교체를 한 번으로 제한합니다.
    static func fragmentsAfterErasing(
        _ annotation: PDFAnnotation,
        around centers: [CGPoint],
        eraserRadius: CGFloat
    ) -> [StrokeFragment]? {
        guard !centers.isEmpty,
              let stored = storedStrokes(in: annotation) else { return nil }
        var updatedFragments: [StrokeFragment] = []
        updatedFragments.reserveCapacity(stored.fragments.count)
        var didErase = false

        for fragment in stored.fragments {
            let widestPressure = fragment.pressures.max() ?? 0.5
            let strokeRadius = PortalPDFVariableWidthStroke.lineWidth(
                for: widestPressure,
                baseLineWidth: stored.baseLineWidth
            ) / 2
            guard let fragmentBounds = fragment.points.boundingRect else { continue }
            let hitBounds = fragmentBounds.insetBy(
                dx: -(eraserRadius + strokeRadius),
                dy: -(eraserRadius + strokeRadius)
            )
            let relevantCenters = centers.filter(hitBounds.contains)
            guard !relevantCenters.isEmpty else {
                updatedFragments.append(fragment)
                continue
            }

            var remainingFragments = [fragment]
            for center in relevantCenters where !remainingFragments.isEmpty {
                remainingFragments = remainingFragments.flatMap { currentFragment -> [StrokeFragment] in
                    guard let result = fragmentsAfterErasing(
                        currentFragment,
                        around: center,
                        eraserRadius: eraserRadius,
                        baseLineWidth: stored.baseLineWidth
                    ) else {
                        return [currentFragment]
                    }
                    didErase = true
                    return result
                }
            }
            updatedFragments.append(contentsOf: remainingFragments)
        }
        return didErase ? updatedFragments : nil
    }

    /// 남은 압력 획 조각을 Annotation 하나로 다시 구성해 조각 수 증가를 차단합니다.
    static func groupedAnnotation(
        fragments: [StrokeFragment],
        baseLineWidth: CGFloat,
        color: UIColor
    ) -> PortalPDFPressureInkAnnotation? {
        guard !fragments.isEmpty else { return nil }
        return PortalPDFPressureInkAnnotation(
            fragments: fragments,
            baseLineWidth: baseLineWidth,
            color: color
        )
    }

    /// 이전 버전에서 여러 Annotation으로 분리된 압력 획을 스타일별 복합 Annotation으로 압축합니다.
    static func compactedAnnotations(
        from annotations: [PDFAnnotation]
    ) -> [PortalPDFPressureInkAnnotation] {
        var fragmentsByStyle: [StrokeStyleKey: [StrokeFragment]] = [:]
        var attributesByStyle: [StrokeStyleKey: (lineWidth: CGFloat, color: UIColor)] = [:]

        for annotation in annotations {
            guard let stored = storedStrokes(in: annotation) else { continue }
            let color = storedColor(in: annotation)
            let key = StrokeStyleKey(
                lineWidth: Int((stored.baseLineWidth * 1_000).rounded()),
                rgba: color.portalRGBA.map { Int(($0 * 10_000).rounded()) }
            )
            fragmentsByStyle[key, default: []].append(contentsOf: stored.fragments)
            attributesByStyle[key] = (stored.baseLineWidth, color)
        }

        return fragmentsByStyle.compactMap { key, fragments in
            guard let attributes = attributesByStyle[key] else { return nil }
            return groupedAnnotation(
                fragments: fragments,
                baseLineWidth: attributes.lineWidth,
                color: attributes.color
            )
        }
    }

    static func fragmentsAfterErasing(
        _ stroke: StrokeFragment,
        around center: CGPoint,
        eraserRadius: CGFloat,
        baseLineWidth: CGFloat
    ) -> [StrokeFragment]? {
        guard !stroke.points.isEmpty,
              stroke.points.count == stroke.pressures.count else { return nil }

        if stroke.points.count == 1 {
            let strokeRadius = PortalPDFVariableWidthStroke.lineWidth(
                for: stroke.pressures[0],
                baseLineWidth: baseLineWidth
            ) / 2
            return hypot(center.x - stroke.points[0].x, center.y - stroke.points[0].y)
                <= eraserRadius + strokeRadius ? [] : nil
        }

        var fragments: [StrokeFragment] = []
        var currentPoints: [CGPoint] = []
        var currentPressures: [CGFloat] = []
        var didErase = false

        func finishCurrentFragment() {
            guard currentPoints.count > 1 else {
                currentPoints.removeAll(keepingCapacity: true)
                currentPressures.removeAll(keepingCapacity: true)
                return
            }
            fragments.append(StrokeFragment(points: currentPoints, pressures: currentPressures))
            currentPoints.removeAll(keepingCapacity: true)
            currentPressures.removeAll(keepingCapacity: true)
        }

        for index in 0..<(stroke.points.count - 1) {
            let start = stroke.points[index]
            let end = stroke.points[index + 1]
            let startPressure = stroke.pressures[index]
            let endPressure = stroke.pressures[index + 1]
            let widestPressure = max(startPressure, endPressure)
            let effectiveRadius = eraserRadius + PortalPDFVariableWidthStroke.lineWidth(
                for: widestPressure,
                baseLineWidth: baseLineWidth
            ) / 2
            let intervals = outsideIntervals(
                from: start,
                to: end,
                center: center,
                radius: effectiveRadius
            )
            if intervals.count != 1 || intervals.first?.0 != 0 || intervals.first?.1 != 1 {
                didErase = true
            }

            for (startT, endT) in intervals where endT - startT > 0.001 {
                let clippedStart = interpolate(start, end, at: startT)
                let clippedEnd = interpolate(start, end, at: endT)
                let clippedStartPressure = interpolate(startPressure, endPressure, at: startT)
                let clippedEndPressure = interpolate(startPressure, endPressure, at: endT)

                if let lastPoint = currentPoints.last,
                   hypot(lastPoint.x - clippedStart.x, lastPoint.y - clippedStart.y) > 0.01 {
                    finishCurrentFragment()
                }
                if currentPoints.isEmpty {
                    currentPoints = [clippedStart]
                    currentPressures = [clippedStartPressure]
                }
                currentPoints.append(clippedEnd)
                currentPressures.append(clippedEndPressure)

                if endT < 0.999 {
                    finishCurrentFragment()
                }
            }
            if intervals.isEmpty {
                finishCurrentFragment()
            }
        }
        finishCurrentFragment()
        return didErase ? fragments : nil
    }

    static func containsStroke(
        _ point: CGPoint,
        points: [CGPoint],
        pressures: [CGFloat],
        baseLineWidth: CGFloat,
        extraRadius: CGFloat
    ) -> Bool {
        guard !points.isEmpty, points.count == pressures.count else { return false }
        if points.count == 1 {
            let radius = PortalPDFVariableWidthStroke.lineWidth(
                for: pressures.first ?? 0.5,
                baseLineWidth: baseLineWidth
            ) / 2 + extraRadius
            return hypot(point.x - points[0].x, point.y - points[0].y) <= radius
        }

        for index in 0..<(points.count - 1) {
            let pressure = (pressures[index] + pressures[index + 1]) / 2
            let radius = PortalPDFVariableWidthStroke.lineWidth(
                for: pressure,
                baseLineWidth: baseLineWidth
            ) / 2 + extraRadius
            if point.distance(toSegmentFrom: points[index], to: points[index + 1]) <= radius {
                return true
            }
        }
        return false
    }

    static func encodedMetadata(
        points: [CGPoint],
        pressures: [CGFloat],
        baseLineWidth: CGFloat,
        color: UIColor
    ) -> String? {
        encodedCompactMetadata(
            fragments: [StrokeFragment(points: points, pressures: pressures)],
            baseLineWidth: baseLineWidth,
            color: color
        )
    }

    static func encodedGroupedMetadata(
        fragments: [StrokeFragment],
        baseLineWidth: CGFloat,
        color: UIColor
    ) -> String? {
        encodedCompactMetadata(
            fragments: fragments,
            baseLineWidth: baseLineWidth,
            color: color
        )
    }

    /// 0.01pt 단위 좌표 delta와 16비트 압력으로 저장해 JSON·Base64 메타데이터를 대폭 줄입니다.
    static func encodedCompactMetadata(
        fragments: [StrokeFragment],
        baseLineWidth: CGFloat,
        color: UIColor
    ) -> String? {
        let validFragments = fragments.filter {
            !$0.points.isEmpty && $0.points.count == $0.pressures.count
        }
        guard validFragments.count <= Int(UInt16.max) else { return nil }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let hasRGBA = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        var data = Data()
        appendCompactValue(UInt8(1), to: &data)
        appendCompactValue(UInt8(hasRGBA ? 1 : 0), to: &data)
        appendCompactValue(UInt16(validFragments.count), to: &data)
        appendCompactValue(Float32(baseLineWidth).bitPattern, to: &data)
        if hasRGBA {
            [red, green, blue, alpha].forEach {
                appendCompactValue(
                    UInt16(min(65_535, max(0, (Double($0) * 65_535).rounded()))),
                    to: &data
                )
            }
        }

        for fragment in validFragments {
            guard fragment.points.count <= Int(UInt32.max) else { return nil }
            appendCompactValue(UInt32(fragment.points.count), to: &data)
            var previousX: Int32 = 0
            var previousY: Int32 = 0
            for (index, point) in fragment.points.enumerated() {
                let currentX = compactCoordinate(point.x)
                let currentY = compactCoordinate(point.y)
                let encodedX = index == 0
                    ? currentX
                    : Int32(clamping: Int64(currentX) - Int64(previousX))
                let encodedY = index == 0
                    ? currentY
                    : Int32(clamping: Int64(currentY) - Int64(previousY))
                appendCompactValue(encodedX, to: &data)
                appendCompactValue(encodedY, to: &data)
                appendCompactValue(compactPressure(fragment.pressures[index]), to: &data)
                previousX = currentX
                previousY = currentY
            }
        }
        return compactMetadataPrefix + data.base64EncodedString()
    }

    private static func decodedCompactMetadata(from annotation: PDFAnnotation) -> CompactMetadata? {
        guard annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .caseInsensitiveCompare(PDFAnnotationSubtype.stamp.rawValue
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))) == .orderedSame,
              let contents = annotation.contents,
              contents.hasPrefix(compactMetadataPrefix),
              let data = Data(base64Encoded: String(contents.dropFirst(compactMetadataPrefix.count))) else {
            return nil
        }
        var reader = CompactMetadataReader(data: data)
        guard reader.read(UInt8.self) == 1,
              let flags = reader.read(UInt8.self),
              let strokeCount = reader.read(UInt16.self),
              let lineWidthBits = reader.read(UInt32.self) else {
            return nil
        }
        let colorRGBA: [CGFloat]?
        if flags & 1 == 1 {
            guard let red = reader.read(UInt16.self),
                  let green = reader.read(UInt16.self),
                  let blue = reader.read(UInt16.self),
                  let alpha = reader.read(UInt16.self) else {
                return nil
            }
            colorRGBA = [red, green, blue, alpha].map { CGFloat($0) / 65_535 }
        } else {
            colorRGBA = nil
        }

        var fragments: [StrokeFragment] = []
        fragments.reserveCapacity(Int(strokeCount))
        for _ in 0..<strokeCount {
            guard let pointCount = reader.read(UInt32.self), pointCount > 0 else { return nil }
            var points: [CGPoint] = []
            var pressures: [CGFloat] = []
            points.reserveCapacity(Int(pointCount))
            pressures.reserveCapacity(Int(pointCount))
            var previousX: Int32 = 0
            var previousY: Int32 = 0
            for index in 0..<pointCount {
                guard let encodedX = reader.read(Int32.self),
                      let encodedY = reader.read(Int32.self),
                      let encodedPressure = reader.read(UInt16.self) else {
                    return nil
                }
                let currentX = index == 0
                    ? encodedX
                    : Int32(clamping: Int64(previousX) + Int64(encodedX))
                let currentY = index == 0
                    ? encodedY
                    : Int32(clamping: Int64(previousY) + Int64(encodedY))
                points.append(
                    CGPoint(
                        x: CGFloat(currentX) / 100,
                        y: CGFloat(currentY) / 100
                    )
                )
                pressures.append(CGFloat(encodedPressure) / 65_535)
                previousX = currentX
                previousY = currentY
            }
            fragments.append(StrokeFragment(points: points, pressures: pressures))
        }
        return CompactMetadata(
            fragments: fragments,
            baseLineWidth: CGFloat(Float32(bitPattern: lineWidthBits)),
            colorRGBA: colorRGBA
        )
    }

    private static func appendCompactValue<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) {
            data.append(contentsOf: $0)
        }
    }

    private static func compactCoordinate(_ value: CGFloat) -> Int32 {
        Int32(clamping: Int64((Double(value) * 100).rounded()))
    }

    private static func compactPressure(_ value: CGFloat) -> UInt16 {
        UInt16(min(65_535, max(0, (Double(value) * 65_535).rounded())))
    }

    static func decodedMetadata(from annotation: PDFAnnotation) -> Metadata? {
        guard annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .caseInsensitiveCompare(PDFAnnotationSubtype.stamp.rawValue
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))) == .orderedSame,
              let contents = annotation.contents,
              contents.hasPrefix(metadataPrefix),
              let data = Data(base64Encoded: String(contents.dropFirst(metadataPrefix.count))) else {
            return nil
        }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    static func decodedGroupedMetadata(from annotation: PDFAnnotation) -> GroupedMetadata? {
        guard annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .caseInsensitiveCompare(PDFAnnotationSubtype.stamp.rawValue
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))) == .orderedSame,
              let contents = annotation.contents,
              contents.hasPrefix(groupedMetadataPrefix),
              let data = Data(base64Encoded: String(contents.dropFirst(groupedMetadataPrefix.count))) else {
            return nil
        }
        return try? JSONDecoder().decode(GroupedMetadata.self, from: data)
    }

    static func storedStrokes(
        in annotation: PDFAnnotation
    ) -> (fragments: [StrokeFragment], baseLineWidth: CGFloat)? {
        if let pressureAnnotation = annotation as? PortalPDFPressureInkAnnotation {
            return (
                pressureAnnotation.strokeFragments,
                pressureAnnotation.baseLineWidth
            )
        }
        if let compactMetadata = decodedCompactMetadata(from: annotation) {
            return (compactMetadata.fragments, compactMetadata.baseLineWidth)
        }
        if let metadata = decodedGroupedMetadata(from: annotation) {
            return (decodedFragments(from: metadata), CGFloat(metadata.baseLineWidth))
        }
        guard let metadata = decodedMetadata(from: annotation) else { return nil }
        let points = metadata.points.compactMap { coordinates -> CGPoint? in
            guard coordinates.count == 2 else { return nil }
            return CGPoint(x: coordinates[0], y: coordinates[1])
        }
        let pressures = metadata.pressures.map { CGFloat($0) }
        guard points.count == pressures.count else { return nil }
        return ([StrokeFragment(points: points, pressures: pressures)], CGFloat(metadata.baseLineWidth))
    }

    static func historyStrokes(
        in annotation: PDFAnnotation
    ) -> (fragments: [StrokeFragment], lineWidth: CGFloat)? {
        guard let stored = storedStrokes(in: annotation) else { return nil }
        return (stored.fragments, stored.baseLineWidth)
    }

    static func decodedFragments(from metadata: GroupedMetadata) -> [StrokeFragment] {
        metadata.strokes.compactMap { stroke in
            let points = stroke.points.compactMap { coordinates -> CGPoint? in
                guard coordinates.count == 2 else { return nil }
                return CGPoint(x: coordinates[0], y: coordinates[1])
            }
            let pressures = stroke.pressures.map { CGFloat($0) }
            guard !points.isEmpty, points.count == pressures.count else { return nil }
            return StrokeFragment(points: points, pressures: pressures)
        }
    }

    static func outsideIntervals(
        from start: CGPoint,
        to end: CGPoint,
        center: CGPoint,
        radius: CGFloat
    ) -> [(CGFloat, CGFloat)] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let fx = start.x - center.x
        let fy = start.y - center.y
        let a = dx * dx + dy * dy
        guard a > 0.0001 else {
            return hypot(start.x - center.x, start.y - center.y) > radius ? [(0, 1)] : []
        }

        let b = 2 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - radius * radius
        let discriminant = b * b - 4 * a * c
        guard discriminant > 0 else { return c > 0 ? [(0, 1)] : [] }

        let root = sqrt(discriminant)
        let first = max(0, min(1, (-b - root) / (2 * a)))
        let second = max(0, min(1, (-b + root) / (2 * a)))
        let cuts = Array(Set([CGFloat(0), first, second, CGFloat(1)])).sorted()
        return (0..<(cuts.count - 1)).compactMap { index in
            let startT = cuts[index]
            let endT = cuts[index + 1]
            let midpoint = interpolate(start, end, at: (startT + endT) / 2)
            return hypot(midpoint.x - center.x, midpoint.y - center.y) > radius
                ? (startT, endT)
                : nil
        }
    }

    static func interpolate(_ start: CGPoint, _ end: CGPoint, at progress: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    static func interpolate(_ start: CGFloat, _ end: CGFloat, at progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}

/**
 선택한 박스 도형의 화면 미리보기와 PDF 저장 경로를 동일하게 생성합니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.31
 */
