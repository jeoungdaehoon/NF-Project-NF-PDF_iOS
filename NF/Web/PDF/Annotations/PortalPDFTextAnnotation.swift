//
// PortalPDFTextAnnotation.swift
// NF
//
// Editable text annotations rendered in PDF page coordinates.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

final class PortalPDFTextAnnotation: PDFAnnotation {
    static let metadataPrefix = "NF_EDITABLE_TEXT_V1:"

    struct Metadata: Codable {
        let id: UUID
        let text: String
        let bounds: CGRect
        let fontName: String
        let fontSize: Double
        let textColorRGBA: [Double]
        let fillColorRGBA: [Double]
        let borderColorRGBA: [Double]
        let isBold: Bool
        let isItalic: Bool
        let isUnderlined: Bool
        let isStruckThrough: Bool
        let alignmentRawValue: Int
        let linkURL: String?
        let attributedTextRTF: Data?
    }

    let textID: UUID
    var textBounds: CGRect
    var portalAlignment: NSTextAlignment

    var text: String {
        didSet { prepareForPersistence() }
    }
    var fontName: String {
        didSet { prepareForPersistence() }
    }
    var fontSize: CGFloat {
        didSet { prepareForPersistence() }
    }
    var textColor: UIColor {
        didSet { prepareForPersistence() }
    }
    /// UIKit 입력기가 표시되는 동안 PDFKit이 동일한 문구를 중복 렌더링하지 않도록 합니다.
    var isPortalTextEditing = false
    /// 텍스트 도구에서 첫 번째 탭으로 활성화된 박스의 외곽선을 표시합니다.
    var isPortalTextSelected = false {
        didSet { updatePresentationBounds() }
    }
    var fillColor: UIColor {
        didSet { prepareForPersistence() }
    }
    var borderColor: UIColor {
        didSet { prepareForPersistence() }
    }
    var isBold: Bool {
        didSet { prepareForPersistence() }
    }
    var isItalic: Bool {
        didSet { prepareForPersistence() }
    }
    var isUnderlined: Bool {
        didSet { prepareForPersistence() }
    }
    var isStruckThrough: Bool {
        didSet { prepareForPersistence() }
    }
    override var alignment: NSTextAlignment {
        get { portalAlignment }
        set {
            portalAlignment = newValue
            prepareForPersistence()
        }
    }
    var linkURL: String? {
        didSet { prepareForPersistence() }
    }
    private var attributedTextRTF: Data?

    var editingBounds: CGRect {
        get { textBounds }
        set {
            textBounds = newValue.standardized
            updatePresentationBounds()
            prepareForPersistence()
        }
    }

    /// 이미지 주석과 동일하게 텍스트 바깥에 표시하는 점선 선택 영역의 간격입니다.
    private static let selectionPadding: CGFloat = 12
    /// 박스 편집과 동일한 모서리·변 중앙 사각 조절점의 화면 기준 한 변 길이입니다.
    private static let resizeHandleSide: CGFloat = 10
    /// 이미지 삭제 버튼과 동일한 PDF Page 기준 지름과 외곽 여백입니다.
    private static let deleteHandleDiameter: CGFloat = 24
    private static let deleteHandleMargin: CGFloat = 3
    private static let clippingSafetyMargin: CGFloat = 3
    private static let minimumEditingDisplayScaleFactor: CGFloat = 0.5
    /// PDF 확대 배율과 반대로 보정해 점선과 삭제 버튼의 화면상 크기를 일정하게 유지합니다.
    private var editingDisplayScaleFactor: CGFloat = 1
    private var selectionDisplayScaleFactor: CGFloat = 1

    private var displayedSelectionLineWidth: CGFloat {
        1 / selectionDisplayScaleFactor
    }

    private var displayedSelectionDashLengths: [CGFloat] {
        [4 / selectionDisplayScaleFactor, 3 / selectionDisplayScaleFactor]
    }

    private var displayedSelectionPadding: CGFloat {
        Self.selectionPadding / selectionDisplayScaleFactor
    }

    private var displayedDeleteHandleDiameter: CGFloat {
        Self.deleteHandleDiameter / editingDisplayScaleFactor
    }

    private var displayedResizeHandleSide: CGFloat {
        Self.resizeHandleSide / editingDisplayScaleFactor
    }

    private var displayedDeleteHandleMargin: CGFloat {
        Self.deleteHandleMargin / editingDisplayScaleFactor
    }

    private var selectionOutlineRect: CGRect {
        textBounds.insetBy(dx: -displayedSelectionPadding, dy: -displayedSelectionPadding)
    }

    var deleteHandleCenter: CGPoint {
        let outlineRect = selectionOutlineRect
        let offset = displayedDeleteHandleDiameter / 2 + displayedDeleteHandleMargin
        return CGPoint(
            x: outlineRect.minX - offset,
            y: outlineRect.maxY + offset
        )
    }

    /// 점선 테두리 위 모서리 4개와 변 중앙 4개의 조절점 중심입니다.
    private var resizeHandleCenters: [PortalPDFResizeHandle: CGPoint] {
        let outlineRect = selectionOutlineRect
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

    /// 현재 PDFView 확대 배율을 이미지 주석과 같은 선택 UI 크기 보정에 반영합니다.
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

    func isDeleteHandleHit(_ point: CGPoint, scaleFactor: CGFloat) -> Bool {
        updateEditingDisplayScaleFactor(scaleFactor)
        let radius = max(displayedDeleteHandleDiameter / 2, 22 / max(scaleFactor, 0.01))
        return hypot(point.x - deleteHandleCenter.x, point.y - deleteHandleCenter.y) <= radius
    }

    /// 터치 위치와 가장 가까운 텍스트 박스 크기 조절점을 반환합니다.
    func resizeHandle(at point: CGPoint, scaleFactor: CGFloat) -> PortalPDFResizeHandle? {
        updateEditingDisplayScaleFactor(scaleFactor)
        let screenAdjustedRadius = 22 / max(scaleFactor, 0.01)
        let hitRadius = max(displayedResizeHandleSide / 2, screenAdjustedRadius)
        return resizeHandleCenters
            .map { (handle: $0.key, distance: hypot(point.x - $0.value.x, point.y - $0.value.y)) }
            .filter { $0.distance <= hitRadius }
            .min(by: { $0.distance < $1.distance })?
            .handle
    }

    func updatePresentationBounds() {
        guard isPortalTextSelected else {
            bounds = textBounds
            return
        }
        let diameter = displayedDeleteHandleDiameter
        let resizePadding = displayedResizeHandleSide / 2
        let resizeBounds = selectionOutlineRect.insetBy(dx: -resizePadding, dy: -resizePadding)
        let deleteRect = CGRect(
            x: deleteHandleCenter.x - diameter / 2,
            y: deleteHandleCenter.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        bounds = resizeBounds
            .union(deleteRect)
            .insetBy(dx: -Self.clippingSafetyMargin, dy: -Self.clippingSafetyMargin)
    }

    var linkAnnotationUserName: String {
        "NF Editable Text Link \(textID.uuidString)"
    }

    var resolvedFont: UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if isBold { traits.insert(.traitBold) }
        if isItalic { traits.insert(.traitItalic) }
        let baseDescriptor = UIFontDescriptor(name: fontName, size: fontSize)
        let descriptor = baseDescriptor.withSymbolicTraits(traits) ?? baseDescriptor
        return UIFont(descriptor: descriptor, size: fontSize)
    }

    var textAttributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        return [
            .font: resolvedFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
            .underlineStyle: isUnderlined ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: isStruckThrough ? NSUnderlineStyle.single.rawValue : 0,
        ]
    }

    var attributedText: NSAttributedString {
        if let attributedTextRTF,
           let decoded = try? NSAttributedString(
                data: attributedTextRTF,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
           ),
           decoded.string == text {
            return decoded
        }
        return NSAttributedString(string: text, attributes: textAttributes)
    }

    /// 범위별 문자 서식을 RTF로 저장해 PDFView 재진입 후에도 그대로 복원합니다.
    func setAttributedText(_ value: NSAttributedString) {
        let fullRange = NSRange(location: 0, length: value.length)
        attributedTextRTF = try? value.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        text = value.string
    }

    init(
        text: String,
        bounds: CGRect,
        borderColor: UIColor = .clear,
        fillColor: UIColor = .clear,
        textColor: UIColor = .black
    ) {
        self.textID = UUID()
        self.textBounds = bounds.standardized
        self.text = text
        self.fontName = UIFont.systemFont(ofSize: 16).fontName
        self.fontSize = 16
        self.textColor = textColor
        self.fillColor = fillColor
        self.borderColor = borderColor
        self.isBold = false
        self.isItalic = false
        self.isUnderlined = false
        self.isStruckThrough = false
        self.portalAlignment = .left
        self.linkURL = nil
        self.attributedTextRTF = nil
        super.init(bounds: bounds.standardized, forType: .stamp, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
        prepareForPersistence()
    }

    init(metadata: Metadata) {
        self.textID = metadata.id
        self.textBounds = metadata.bounds.standardized
        self.text = metadata.text
        self.fontName = metadata.fontName
        self.fontSize = CGFloat(metadata.fontSize)
        self.textColor = UIColor.portalColor(rgba: metadata.textColorRGBA) ?? .black
        self.fillColor = UIColor.portalColor(rgba: metadata.fillColorRGBA) ?? UIColor.white.withAlphaComponent(0.92)
        self.borderColor = UIColor.portalColor(rgba: metadata.borderColorRGBA) ?? .systemBlue
        self.isBold = metadata.isBold
        self.isItalic = metadata.isItalic
        self.isUnderlined = metadata.isUnderlined
        self.isStruckThrough = metadata.isStruckThrough
        self.portalAlignment = NSTextAlignment(rawValue: metadata.alignmentRawValue) ?? .left
        self.linkURL = metadata.linkURL
        self.attributedTextRTF = metadata.attributedTextRTF
        super.init(bounds: metadata.bounds.standardized, forType: .stamp, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
        prepareForPersistence()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    static func restored(from annotation: PDFAnnotation) -> PortalPDFTextAnnotation? {
        guard let contents = annotation.contents,
              contents.hasPrefix(metadataPrefix),
              let data = Data(base64Encoded: String(contents.dropFirst(metadataPrefix.count))),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { return nil }
        return PortalPDFTextAnnotation(metadata: metadata)
    }

    func prepareForPersistence() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let metadata = Metadata(
            id: textID,
            text: text,
            bounds: textBounds,
            fontName: fontName,
            fontSize: Double(fontSize),
            textColorRGBA: textColor.portalRGBA,
            fillColorRGBA: fillColor.portalRGBA,
            borderColorRGBA: borderColor.portalRGBA,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStruckThrough: isStruckThrough,
            alignmentRawValue: alignment.rawValue,
            linkURL: linkURL,
            attributedTextRTF: attributedTextRTF
        )
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        contents = Self.metadataPrefix + data.base64EncodedString()
        userName = "NF Editable Text"
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !isPortalTextEditing else { return }
        context.saveGState()
        let drawingBounds = textBounds.standardized
        if fillColor.cgColor.alpha > 0 {
            context.setFillColor(fillColor.cgColor)
            context.fill(drawingBounds)
        }
        if borderColor.cgColor.alpha > 0 {
            context.setStrokeColor(borderColor.cgColor)
            context.setLineWidth(max(0.75, 1 / max(1, UIScreen.main.scale)))
            context.stroke(drawingBounds.insetBy(dx: 0.5, dy: 0.5))
        }
        if isPortalTextSelected {
            let outlineInset = 1.5 / selectionDisplayScaleFactor
            let outlineRect = selectionOutlineRect.insetBy(dx: outlineInset, dy: outlineInset)
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(displayedSelectionLineWidth)
            context.setLineDash(phase: 0, lengths: displayedSelectionDashLengths)
            context.stroke(outlineRect)
            context.setLineDash(phase: 0, lengths: [])
            drawResizeHandles(in: context)

            let diameter = displayedDeleteHandleDiameter
            let deleteRect = CGRect(
                x: deleteHandleCenter.x - diameter / 2,
                y: deleteHandleCenter.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.setFillColor(UIColor.systemRed.cgColor)
            context.fillEllipse(in: deleteRect)
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(2 / editingDisplayScaleFactor)
            let iconInset = 7 / editingDisplayScaleFactor
            context.move(to: CGPoint(x: deleteRect.minX + iconInset, y: deleteRect.minY + iconInset))
            context.addLine(to: CGPoint(x: deleteRect.maxX - iconInset, y: deleteRect.maxY - iconInset))
            context.move(to: CGPoint(x: deleteRect.maxX - iconInset, y: deleteRect.minY + iconInset))
            context.addLine(to: CGPoint(x: deleteRect.minX + iconInset, y: deleteRect.maxY - iconInset))
            context.strokePath()
        }

        let textRect = drawingBounds.insetBy(dx: 8, dy: 8)
        let attributedString = attributedText
        if attributedString.length > 0, textRect.width > 0, textRect.height > 0 {
            let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: attributedString.length),
                path,
                nil
            )
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
        }
        context.restoreGState()
    }

    /// 박스 편집과 동일한 흰색 사각 조절점 8개를 텍스트 선택 점선 위에 표시합니다.
    private func drawResizeHandles(in context: CGContext) {
        let side = displayedResizeHandleSide
        let halfSide = side / 2
        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(displayedSelectionLineWidth)
        resizeHandleCenters.values.forEach { center in
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
}

/**
 PDF 페이지 위에 선택한 박스 도형을 직접 그리는 Annotation 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.31
 */
