//
// PortalPDFImageCropEditor.swift
// NF
//
// Rectangle and freehand cropping for selected PDF image annotations.
//

import SwiftUI
import UIKit

/// 이미지 자르기 화면에서 사용할 선택 방식입니다.
private enum PortalPDFImageCropMode: String, CaseIterable, Identifiable {
    case rectangle
    case freehand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: return "영역 조절"
        case .freehand: return "선 그리기"
        }
    }

    var instruction: String {
        switch self {
        case .rectangle:
            return "영역 안을 드래그해 이미지를 이동하거나 네 모서리를 조절해 자를 범위를 정하세요."
        case .freehand:
            return "남길 영역의 외곽선을 손가락으로 이어 그리세요. 시작점과 끝점은 자동으로 연결됩니다."
        }
    }
}

/// 사각형 자르기 영역의 네 모서리 조절점입니다.
private enum PortalPDFImageCropHandle: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// 핀치가 시작된 순간의 이미지 변환값을 보관해 손가락 중심을 유지하며 확대합니다.
private struct PortalPDFImageCropZoomStart {
    let scale: CGFloat
    let offset: CGSize
}

/// 선택 이미지의 사각형 영역 또는 자유선 영역을 실제 래스터로 잘라 반환합니다.
struct PortalPDFImageCropEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.portalAppTheme) private var portalTheme

    let item: PortalPDFImageCropEditorItem
    let onCropped: (PortalPDFImageCropResult) -> Void

    @State private var mode: PortalPDFImageCropMode = .rectangle
    @State private var normalizedCropRect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    @State private var normalizedFreehandPoints: [CGPoint] = []
    @State private var rectangleGestureStart: CGRect?
    @State private var isDrawingFreehand = false
    @State private var keepsOriginalImage = false
    @State private var errorMessage: String?
    @State private var zoomScale: CGFloat = 1
    @State private var imageOffset: CGSize = .zero
    @State private var zoomGestureStart: PortalPDFImageCropZoomStart?
    @GestureState private var transientImageOffset: CGSize = .zero

    private let cropCanvasCoordinateSpace = "nf.pdf.image.crop.canvas"
    private let minimumCropSide: CGFloat = 0.06
    private let minimumZoomScale: CGFloat = 1
    private let maximumZoomScale: CGFloat = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("자르기 방식", selection: $mode) {
                    ForEach(PortalPDFImageCropMode.allCases) { cropMode in
                        Text(cropMode.title).tag(cropMode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                GeometryReader { geometry in
                    cropCanvas(size: geometry.size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)

                Text(mode.instruction + "\n두 손가락으로 이미지를 확대하거나 축소할 수 있습니다.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(portalTheme.mutedColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)

                HStack(spacing: 12) {
                    Button {
                        resetSelection()
                    } label: {
                        Label("초기화", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        applyCrop()
                    } label: {
                        Label("자르기", systemImage: "crop")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(mode == .freehand && normalizedFreehandPoints.count < 3)
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(portalTheme.backgroundColor.ignoresSafeArea())
            .navigationTitle("이미지 자르기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(portalTheme.backgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(portalTheme.colorScheme, for: .navigationBar)
            .tint(portalTheme.accentColor)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            keepsOriginalImage.toggle()
                        } label: {
                            Label(
                                "원본 이미지 유지",
                                systemImage: keepsOriginalImage ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel("이미지 자르기 더보기")
                    .accessibilityValue(keepsOriginalImage ? "원본 이미지 유지 켜짐" : "원본 이미지 유지 꺼짐")
                }
            }
            .alert("이미지를 자르지 못했습니다.", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "자를 영역을 다시 지정해 주세요.")
            }
        }
        .preferredColorScheme(portalTheme.colorScheme)
    }

    /// 원본 비율을 유지해 화면 안에 배치하고 현재 모드의 편집 오버레이를 올립니다.
    private func cropCanvas(size: CGSize) -> some View {
        let baseImageFrame = aspectFitFrame(imageSize: item.image.size, containerSize: size)
        let selectionRect = imageCoverageSelectionRect
        let imageFrame = transformedImageFrame(
            from: baseImageFrame,
            covering: selectionRect
        )
        return ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)

            Image(uiImage: item.image)
                .resizable()
                .scaledToFit()
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)

            if mode == .rectangle {
                rectangleCropOverlay(
                    in: baseImageFrame,
                    canvasBounds: CGRect(origin: .zero, size: size)
                )
            } else {
                freehandCropOverlay(
                    in: baseImageFrame,
                    canvasBounds: CGRect(origin: .zero, size: size)
                )
            }
        }
        .coordinateSpace(name: cropCanvasCoordinateSpace)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(portalTheme.borderColor, lineWidth: 1)
        }
        .simultaneousGesture(imageZoomGesture(
            baseImageFrame: baseImageFrame,
            canvasSize: size,
            selectionRect: selectionRect
        ))
    }

    /// 핀치 중심 아래의 원본 위치를 유지하면서 이미지만 1~5배 확대합니다.
    private func imageZoomGesture(
        baseImageFrame: CGRect,
        canvasSize: CGSize,
        selectionRect: CGRect
    ) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if zoomGestureStart == nil {
                    zoomGestureStart = PortalPDFImageCropZoomStart(
                        scale: zoomScale,
                        offset: imageOffset
                    )
                }
                guard let start = zoomGestureStart,
                      baseImageFrame.width > 0,
                      baseImageFrame.height > 0 else { return }
                let nextScale = clampedZoomScale(start.scale * value.magnification)
                let anchorPoint = CGPoint(
                    x: value.startAnchor.x * canvasSize.width,
                    y: value.startAnchor.y * canvasSize.height
                )
                let anchor = CGPoint(
                    x: min(max((anchorPoint.x - baseImageFrame.minX) / baseImageFrame.width, 0), 1),
                    y: min(max((anchorPoint.y - baseImageFrame.minY) / baseImageFrame.height, 0), 1)
                )
                let sourcePoint = sourceNormalizedPoint(
                    anchor,
                    scale: start.scale,
                    offset: start.offset
                )
                let proposedOffset = CGSize(
                    width: anchor.x - 0.5 - nextScale * (sourcePoint.x - 0.5),
                    height: anchor.y - 0.5 - nextScale * (sourcePoint.y - 0.5)
                )
                zoomScale = nextScale
                imageOffset = clampedImageOffset(
                    proposedOffset,
                    scale: nextScale,
                    covering: selectionRect
                )
            }
            .onEnded { _ in
                imageOffset = clampedImageOffset(
                    imageOffset,
                    scale: zoomScale,
                    covering: selectionRect
                )
                zoomGestureStart = nil
            }
    }

    private func clampedZoomScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumZoomScale), maximumZoomScale)
    }

    /// 자르기 프레임은 고정하고 이미지에만 확대·이동 변환을 적용합니다.
    private func transformedImageFrame(
        from baseFrame: CGRect,
        covering selectionRect: CGRect
    ) -> CGRect {
        let scale = clampedZoomScale(zoomScale)
        let proposedOffset = CGSize(
            width: imageOffset.width + transientImageOffset.width,
            height: imageOffset.height + transientImageOffset.height
        )
        let offset = clampedImageOffset(proposedOffset, scale: scale, covering: selectionRect)
        let scaledSize = CGSize(
            width: baseFrame.width * scale,
            height: baseFrame.height * scale
        )
        return CGRect(
            x: baseFrame.midX - scaledSize.width / 2 + offset.width * baseFrame.width,
            y: baseFrame.midY - scaledSize.height / 2 + offset.height * baseFrame.height,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    private var imageCoverageSelectionRect: CGRect {
        mode == .rectangle
            ? normalizedCropRect
            : CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// 확대된 이미지가 현재 자르기 영역을 완전히 덮도록 이동 범위를 제한합니다.
    private func clampedImageOffset(
        _ proposedOffset: CGSize,
        scale: CGFloat,
        covering selectionRect: CGRect
    ) -> CGSize {
        let minimumX = selectionRect.maxX - (0.5 + scale / 2)
        let maximumX = selectionRect.minX - (0.5 - scale / 2)
        let minimumY = selectionRect.maxY - (0.5 + scale / 2)
        let maximumY = selectionRect.minY - (0.5 - scale / 2)
        return CGSize(
            width: min(max(proposedOffset.width, minimumX), maximumX),
            height: min(max(proposedOffset.height, minimumY), maximumY)
        )
    }

    /// 이미지가 Canvas를 벗어나지 않도록 Aspect Fit 영역을 계산합니다.
    private func aspectFitFrame(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        let availableSize = CGSize(
            width: max(containerSize.width - 24, 1),
            height: max(containerSize.height - 24, 1)
        )
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: CGPoint(x: 12, y: 12), size: availableSize)
        }
        let scale = min(availableSize.width / imageSize.width, availableSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    /// 사각형 바깥을 어둡게 표시하고 이동 영역, 3분할 Guide, 네 모서리 조절점을 제공합니다.
    private func rectangleCropOverlay(
        in imageFrame: CGRect,
        canvasBounds: CGRect
    ) -> some View {
        let cropFrame = denormalized(normalizedCropRect, in: imageFrame)
        return ZStack {
            Path { path in
                path.addRect(canvasBounds)
                path.addRect(cropFrame)
            }
            .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))

            Rectangle()
                .fill(Color.clear)
                .frame(width: cropFrame.width, height: cropFrame.height)
                .contentShape(Rectangle())
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .gesture(imagePanGesture(in: imageFrame))

            Path { path in
                path.addRect(cropFrame)
                for division in 1...2 {
                    let fraction = CGFloat(division) / 3
                    path.move(to: CGPoint(x: cropFrame.minX + cropFrame.width * fraction, y: cropFrame.minY))
                    path.addLine(to: CGPoint(x: cropFrame.minX + cropFrame.width * fraction, y: cropFrame.maxY))
                    path.move(to: CGPoint(x: cropFrame.minX, y: cropFrame.minY + cropFrame.height * fraction))
                    path.addLine(to: CGPoint(x: cropFrame.maxX, y: cropFrame.minY + cropFrame.height * fraction))
                }
            }
            .stroke(Color.white.opacity(0.88), lineWidth: 1)
            .allowsHitTesting(false)

            ForEach(PortalPDFImageCropHandle.allCases, id: \.self) { handle in
                cropHandle(handle, in: cropFrame, imageFrame: imageFrame)
            }
        }
    }

    /// 고정된 자르기 영역 안에서 이미지만 이동하고 선택 영역 바깥이 노출되지 않게 제한합니다.
    private func imagePanGesture(in imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(cropCanvasCoordinateSpace))
            .updating($transientImageOffset) { value, state, _ in
                guard zoomGestureStart == nil,
                      imageFrame.width > 0,
                      imageFrame.height > 0 else { return }
                state = CGSize(
                    width: value.translation.width / imageFrame.width,
                    height: value.translation.height / imageFrame.height
                )
            }
            .onEnded { value in
                guard zoomGestureStart == nil,
                      imageFrame.width > 0,
                      imageFrame.height > 0 else { return }
                let proposedOffset = CGSize(
                    width: imageOffset.width + value.translation.width / imageFrame.width,
                    height: imageOffset.height + value.translation.height / imageFrame.height
                )
                imageOffset = clampedImageOffset(
                    proposedOffset,
                    scale: zoomScale,
                    covering: normalizedCropRect
                )
            }
    }

    /// 실제 원형은 작게 유지하면서 44pt 터치 영역으로 각 모서리를 조절합니다.
    private func cropHandle(
        _ handle: PortalPDFImageCropHandle,
        in cropFrame: CGRect,
        imageFrame: CGRect
    ) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 17, height: 17)
            .overlay {
                Circle()
                    .stroke(portalTheme.accentColor, lineWidth: 3)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .position(handlePosition(handle, in: cropFrame))
            .gesture(cropHandleGesture(handle, in: imageFrame))
            .accessibilityLabel("자르기 영역 모서리 조절")
    }

    private func handlePosition(_ handle: PortalPDFImageCropHandle, in cropFrame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.minY)
        case .topRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
        case .bottomLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
        case .bottomRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
        }
    }

    /// 손가락 위치를 정규화해 반대편 모서리와 최소 간격을 유지하며 영역을 갱신합니다.
    private func cropHandleGesture(
        _ handle: PortalPDFImageCropHandle,
        in imageFrame: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(cropCanvasCoordinateSpace))
            .onChanged { value in
                if rectangleGestureStart == nil {
                    rectangleGestureStart = normalizedCropRect
                }
                guard let start = rectangleGestureStart else { return }
                let point = normalized(value.location, in: imageFrame)
                var minimumX = start.minX
                var maximumX = start.maxX
                var minimumY = start.minY
                var maximumY = start.maxY

                switch handle {
                case .topLeft:
                    minimumX = min(point.x, maximumX - minimumCropSide)
                    minimumY = min(point.y, maximumY - minimumCropSide)
                case .topRight:
                    maximumX = max(point.x, minimumX + minimumCropSide)
                    minimumY = min(point.y, maximumY - minimumCropSide)
                case .bottomLeft:
                    minimumX = min(point.x, maximumX - minimumCropSide)
                    maximumY = max(point.y, minimumY + minimumCropSide)
                case .bottomRight:
                    maximumX = max(point.x, minimumX + minimumCropSide)
                    maximumY = max(point.y, minimumY + minimumCropSide)
                }

                normalizedCropRect = CGRect(
                    x: max(0, minimumX),
                    y: max(0, minimumY),
                    width: min(1, maximumX) - max(0, minimumX),
                    height: min(1, maximumY) - max(0, minimumY)
                )
            }
            .onEnded { _ in
                rectangleGestureStart = nil
                imageOffset = clampedImageOffset(
                    imageOffset,
                    scale: zoomScale,
                    covering: normalizedCropRect
                )
            }
    }

    /// 손가락으로 그린 자유선과 자동으로 닫힌 선택 영역을 표시합니다.
    private func freehandCropOverlay(
        in imageFrame: CGRect,
        canvasBounds: CGRect
    ) -> some View {
        let path = freehandPath(in: imageFrame)
        return ZStack {
            if normalizedFreehandPoints.count >= 3 {
                Path { mask in
                    mask.addRect(canvasBounds)
                    mask.addPath(path)
                }
                .fill(Color.black.opacity(0.56), style: FillStyle(eoFill: true))

                path
                    .fill(portalTheme.accentColor.opacity(0.14))
            }

            path
                .stroke(
                    portalTheme.accentColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )

            Rectangle()
                .fill(Color.clear)
                .frame(width: imageFrame.width, height: imageFrame.height)
                .contentShape(Rectangle())
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .gesture(freehandDrawingGesture(in: imageFrame))
        }
    }

    private func freehandPath(in imageFrame: CGRect) -> Path {
        var path = Path()
        guard let firstPoint = normalizedFreehandPoints.first else { return path }
        path.move(to: denormalized(firstPoint, in: imageFrame))
        normalizedFreehandPoints.dropFirst().forEach { point in
            path.addLine(to: denormalized(point, in: imageFrame))
        }
        if !isDrawingFreehand, normalizedFreehandPoints.count >= 3 {
            path.closeSubpath()
        }
        return path
    }

    /// 자유선 입력이 새로 시작되면 이전 경로를 지우고 일정 간격 이상의 지점만 기록합니다.
    private func freehandDrawingGesture(in imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(cropCanvasCoordinateSpace))
            .onChanged { value in
                if !isDrawingFreehand {
                    normalizedFreehandPoints = []
                    isDrawingFreehand = true
                }
                let point = normalized(value.location, in: imageFrame)
                if let lastPoint = normalizedFreehandPoints.last {
                    let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
                    guard distance >= 0.004 else { return }
                }
                normalizedFreehandPoints.append(point)
            }
            .onEnded { _ in
                isDrawingFreehand = false
            }
    }

    private func normalized(_ point: CGPoint, in imageFrame: CGRect) -> CGPoint {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((point.x - imageFrame.minX) / imageFrame.width, 0), 1),
            y: min(max((point.y - imageFrame.minY) / imageFrame.height, 0), 1)
        )
    }

    private func denormalized(_ point: CGPoint, in imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + point.x * imageFrame.width,
            y: imageFrame.minY + point.y * imageFrame.height
        )
    }

    private func denormalized(_ rect: CGRect, in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + rect.minX * imageFrame.width,
            y: imageFrame.minY + rect.minY * imageFrame.height,
            width: rect.width * imageFrame.width,
            height: rect.height * imageFrame.height
        )
    }

    /// 화면의 고정 자르기 좌표를 확대·이동된 원본 이미지의 정규화 좌표로 역변환합니다.
    private func sourceNormalizedPoint(
        _ point: CGPoint,
        scale: CGFloat,
        offset: CGSize
    ) -> CGPoint {
        let validScale = max(scale, minimumZoomScale)
        return CGPoint(
            x: 0.5 + (point.x - 0.5 - offset.width) / validScale,
            y: 0.5 + (point.y - 0.5 - offset.height) / validScale
        )
    }

    private func sourceNormalizedRect(
        _ rect: CGRect,
        scale: CGFloat,
        offset: CGSize
    ) -> CGRect {
        let minimum = sourceNormalizedPoint(
            CGPoint(x: rect.minX, y: rect.minY),
            scale: scale,
            offset: offset
        )
        let maximum = sourceNormalizedPoint(
            CGPoint(x: rect.maxX, y: rect.maxY),
            scale: scale,
            offset: offset
        )
        return CGRect(
            x: minimum.x,
            y: minimum.y,
            width: maximum.x - minimum.x,
            height: maximum.y - minimum.y
        )
    }

    private func resetSelection() {
        rectangleGestureStart = nil
        isDrawingFreehand = false
        zoomScale = minimumZoomScale
        imageOffset = .zero
        zoomGestureStart = nil
        if mode == .rectangle {
            normalizedCropRect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
        } else {
            normalizedFreehandPoints = []
        }
    }

    /// 현재 모드의 정규화된 선택 영역을 원본 이미지 좌표로 변환해 결과를 반환합니다.
    private func applyCrop() {
        let scale = clampedZoomScale(zoomScale)
        let offset = clampedImageOffset(
            imageOffset,
            scale: scale,
            covering: imageCoverageSelectionRect
        )
        let croppedImage: UIImage?
        switch mode {
        case .rectangle:
            croppedImage = item.image.portalRectangleCrop(normalizedRect: sourceNormalizedRect(
                normalizedCropRect,
                scale: scale,
                offset: offset
            ))
        case .freehand:
            croppedImage = item.image.portalFreehandCrop(normalizedPoints: normalizedFreehandPoints.map {
                sourceNormalizedPoint($0, scale: scale, offset: offset)
            })
        }
        guard let croppedImage else {
            errorMessage = "자를 영역이 너무 작거나 올바르게 닫히지 않았습니다."
            return
        }
        onCropped(PortalPDFImageCropResult(image: croppedImage, keepsOriginal: keepsOriginalImage))
        dismiss()
    }
}

private extension UIImage {
    /// UIKit 표시 방향을 실제 픽셀 방향에 반영해 자르기 좌표와 결과가 어긋나지 않게 합니다.
    var portalCropNormalizedImage: UIImage {
        guard imageOrientation != .up || cgImage == nil else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(scale, 1)
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 정규화된 사각형을 픽셀 영역으로 변환해 원본 해상도로 자릅니다.
    func portalRectangleCrop(normalizedRect: CGRect) -> UIImage? {
        let source = portalCropNormalizedImage
        guard let sourceImage = source.cgImage else { return nil }
        let clampedRect = normalizedRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clampedRect.width >= 0.01, clampedRect.height >= 0.01 else { return nil }
        let pixelBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let pixelCropRect = CGRect(
            x: clampedRect.minX * pixelBounds.width,
            y: clampedRect.minY * pixelBounds.height,
            width: clampedRect.width * pixelBounds.width,
            height: clampedRect.height * pixelBounds.height
        ).integral.intersection(pixelBounds)
        guard pixelCropRect.width >= 2,
              pixelCropRect.height >= 2,
              let croppedImage = sourceImage.cropping(to: pixelCropRect) else { return nil }
        return UIImage(cgImage: croppedImage, scale: source.scale, orientation: .up)
    }

    /// 자유선 폐곡선의 바깥은 투명하게 처리하고 선택 영역의 최소 경계로 결과를 자릅니다.
    func portalFreehandCrop(normalizedPoints: [CGPoint]) -> UIImage? {
        guard normalizedPoints.count >= 3 else { return nil }
        let source = portalCropNormalizedImage
        let clampedPoints = normalizedPoints.map { point in
            CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }
        let pointBounds = clampedPoints.reduce(CGRect.null) { partialResult, point in
            partialResult.union(CGRect(origin: point, size: .zero))
        }.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard pointBounds.width >= 0.01, pointBounds.height >= 0.01 else { return nil }

        let outputSize = CGSize(
            width: source.size.width * pointBounds.width,
            height: source.size.height * pointBounds.height
        )
        guard outputSize.width >= 2, outputSize.height >= 2 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(source.scale, 1)
        format.opaque = false
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            let clippingPath = UIBezierPath()
            for (index, point) in clampedPoints.enumerated() {
                let outputPoint = CGPoint(
                    x: (point.x - pointBounds.minX) * source.size.width,
                    y: (point.y - pointBounds.minY) * source.size.height
                )
                if index == 0 {
                    clippingPath.move(to: outputPoint)
                } else {
                    clippingPath.addLine(to: outputPoint)
                }
            }
            clippingPath.close()
            clippingPath.addClip()
            source.draw(in: CGRect(
                x: -pointBounds.minX * source.size.width,
                y: -pointBounds.minY * source.size.height,
                width: source.size.width,
                height: source.size.height
            ))
        }
    }
}
