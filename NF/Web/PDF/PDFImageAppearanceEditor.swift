import ImageIO
import SwiftUI

struct PDFImageAppearanceEditor: View {
    private let bounds: CGRect
    private let flipped: Bool
    private let startsAtBackground: Bool
    let onBack: () -> Void
    let onApply: (PDFImageAppearance) -> Void
    @State private var draft: PDFImageAppearance
    private let thumbnail: CGImage?

    init(imageData: Data?, bounds: CGRect, flipped: Bool, appearance: PDFImageAppearance?, startsAtBackground: Bool,
         onBack: @escaping () -> Void, onApply: @escaping (PDFImageAppearance) -> Void) {
        self.bounds = bounds
        self.flipped = flipped
        self.startsAtBackground = startsAtBackground
        self.onBack = onBack
        self.onApply = onApply
        var appearance = appearance ?? PDFImageAppearance()
        if startsAtBackground, appearance.backgroundRemoval == nil {
            appearance.backgroundRemoval = .init()
        }
        _draft = State(initialValue: appearance)
        thumbnail = imageData.flatMap { data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ] as CFDictionary)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("이미지 스타일", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                #if os(macOS)
                MacPDFActionButton(title: "뒤로", identifier: "pdf.image.appearance.back", action: onBack)
                    .frame(width: 42, height: 24)
                #else
                Button("취소", action: onBack)
                #endif
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    preview
                    if startsAtBackground {
                        backgroundControls
                        Divider()
                    }
                    borderControls
                    Divider()
                    Picker("그림자", selection: $draft.shadow) {
                        ForEach(PDFImageAppearance.Shadow.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("pdf.image.appearance.shadow")
                    Toggle("반사", isOn: $draft.reflection)
                        .accessibilityIdentifier("pdf.image.appearance.reflection")
                    percentSlider("불투명도", value: $draft.opacity)
                        .accessibilityIdentifier("pdf.image.appearance.opacity")
                    if !startsAtBackground {
                        Divider()
                        backgroundControls
                    }
                    Divider()
                    titleControls
                }
                .padding(12)
            }
            #if os(macOS)
            .frame(height: 420)
            #else
            .frame(maxHeight: 420)
            #endif
            Divider()
            HStack {
                Spacer()
                #if os(macOS)
                MacPDFActionButton(title: "적용", identifier: "pdf.image.appearance.apply") { onApply(draft) }
                    .frame(width: 50, height: 26)
                    .background(Color.accentColor.opacity(0.36), in: RoundedRectangle(cornerRadius: 6))
                #else
                Button("적용") { onApply(draft) }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pdf.image.appearance.apply")
                #endif
            }
            .padding(12)
        }
        #if os(macOS)
        .frame(width: 342)
        .background(MacPDFPanelSurface(radius: 9))
        #else
        .frame(maxWidth: 420)
        .presentationDragIndicator(.visible)
        #endif
    }

    private var borderControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("테두리", selection: $draft.border) {
                ForEach(PDFImageAppearance.Border.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("pdf.image.appearance.border")
            if draft.border != .none {
                HStack {
                    Picker("선 스타일", selection: $draft.line) {
                        ForEach(PDFImageAppearance.Line.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Canvas { context, size in
                        context.withCGContext { graphics in
                            draft.line.stroke([CGPoint(x: 4, y: size.height / 2), CGPoint(x: size.width - 4, y: size.height / 2)],
                                              width: 3, color: draft.borderColor.color, in: graphics)
                        }
                    }
                    .frame(width: 60, height: 18)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
                }
                HStack {
                    ColorPicker("선 색상", selection: Binding(
                        get: { Color(cgColor: draft.borderColor.color.cgColor) },
                        set: { draft.borderColor = PDFImageRGBA(PDFImagePlatformColor($0)) }
                    ))
                    Spacer()
                    Stepper("두께 \(draft.borderWidth, format: .number.precision(.fractionLength(0...2))) pt",
                            value: $draft.borderWidth, in: 0.25...24, step: 0.25)
                        .fixedSize()
                }
            }
        }
    }

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("배경 투명화", isOn: Binding(
                get: { draft.backgroundRemoval != nil },
                set: { draft.backgroundRemoval = $0 ? (draft.backgroundRemoval ?? .init()) : nil }
            ))
            .accessibilityIdentifier("pdf.image.appearance.remove-background")
            if let removal = Binding($draft.backgroundRemoval) {
                percentSlider("색상 허용 범위", value: removal.tolerance)
                percentSlider("투명화 강도", value: removal.strength)
            }
        }
    }

    private var titleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("제목", isOn: $draft.showsTitle)
            if draft.showsTitle {
                TextField("이미지 제목", text: $draft.title).textFieldStyle(.roundedBorder)
                Picker("제목 위치", selection: $draft.titlePosition) {
                    ForEach(PDFImageAppearance.TitlePosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func percentSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: 0...100) {
                Text(label)
            }
            Text("\(Int(value.wrappedValue))%")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var preview: some View {
        Canvas { context, size in
            let tile: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column).isMultiple(of: 2) {
                    let square = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                    context.fill(Path(square), with: .color(Color(white: 0.9)))
                }
            }
            guard let thumbnail, bounds.height > 0, size.width > 60, size.height > 0 else { return }
            let image = draft.backgroundRemoval.map { PDFImageBackgroundRemoval.apply($0, to: thumbnail) } ?? thumbnail
            let ratio = bounds.width / bounds.height
            let height = min(70, (size.width - 60) / max(0.01, ratio))
            let width = height * ratio
            let rect = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let graphics = CGContext(data: nil, width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2)),
                                           bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: bitmapInfo) else { return }
            graphics.scaleBy(x: 2, y: 2)
            var appearance = draft
            appearance.borderWidth = min(8, appearance.borderWidth)
            appearance.draw(image, in: rect, flipped: flipped, attachmentName: nil, context: graphics)
            if let preview = graphics.makeImage() {
                context.draw(Image(decorative: preview, scale: 2), in: CGRect(origin: .zero, size: size))
            }
        }
        .frame(height: 134)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("이미지 스타일 미리보기")
    }
}
