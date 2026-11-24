import AppKit
import Combine
import SwiftUI

@MainActor
final class MacLiveDetailPDFToolbarModel: ObservableObject {
    @Published private(set) var state: LiveDetailPDF.ToolbarState?
    weak var bridge: LiveDetailPDF?

    func update(_ state: LiveDetailPDF.ToolbarState?) {
        if self.state != state { self.state = state }
    }

    func perform(_ command: String, _ value: Any? = nil) {
        bridge?.performToolbarCommand(command, value: value)
    }
}

private enum MacLiveDetailPDFTool: String, CaseIterable, Identifiable {
    case view, hand, select, pen, handwriting, highlighter, neon, eraser, shape, text, image, connector, document, link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .view: "원본 보기·편집"
        case .hand: "손 도구"
        case .handwriting: "손글씨"
        case .text: "텍스트 주석"
        case .image: "이미지 삽입"
        case .document: "문서 연결"
        case .link: "웹 링크 연결"
        default: MacPDFTool(rawValue: rawValue)?.title ?? rawValue
        }
    }

    var symbol: String {
        switch self {
        case .view: "eye"
        case .hand: "hand.draw"
        case .handwriting: "signature"
        case .document: "doc.text"
        case .link: "link"
        default: MacPDFTool(rawValue: rawValue)?.symbol ?? "pencil.tip"
        }
    }
}

struct MacLiveDetailPDFToolbar: View {
    @ObservedObject var model: MacLiveDetailPDFToolbarModel

    var body: some View {
        if let state = model.state, !state.dialogOpen {
            GeometryReader { geometry in
                let size = geometry.size
                let top = min(CGFloat(state.top), max(0, size.height - MacPDFToolbarLayout.horizontalHeight - 6))
                VStack(alignment: .leading, spacing: 6) {
                    palette(state, size: CGSize(width: max(1, size.width - 16), height: size.height))
                    if state.optionsOpen, let tool = MacLiveDetailPDFTool(rawValue: state.tool) {
                        options(state, tool: tool, maxHeight: max(1, min(360, size.height - top - 90)))
                            .frame(width: min(344, max(1, size.width - 16)))
                    }
                    if !state.status.isEmpty {
                        Text(state.status)
                            .font(.caption)
                            .padding(8)
                            .background(MacPDFPanelSurface(radius: 8))
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding(.leading, 8)
                .padding(.top, top)
            }
        }
    }

    private func palette(_ state: LiveDetailPDF.ToolbarState, size: CGSize) -> some View {
        MacPDFToolPalette(vertical: false, availableSize: size) {
            action("close", "상세페이지로 돌아가기", "chevron.left")
            Menu {
                ForEach(MacLiveDetailPDFTool.allCases) { tool in
                    Button {
                        model.perform("tool", tool.rawValue)
                    } label: {
                        Label(tool.title, systemImage: state.tool == tool.rawValue ? "checkmark" : tool.symbol)
                    }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 30)
            .help("도구 지원")
            .accessibilityLabel("도구 지원")
            .accessibilityIdentifier("pdf.live.tools")
            action("settings", "도구 상세 설정", "slider.horizontal.3", enabled: state.settingsAvailable)
            action("undo", "PDF 실행 취소", "arrow.uturn.backward", enabled: state.canUndo)
            action("redo", "PDF 다시 실행", "arrow.uturn.forward", enabled: state.canRedo)
            action("zoomOut", "상세페이지 축소", "minus.magnifyingglass", enabled: state.canZoomOut)
            action("zoomIn", "상세페이지 확대", "plus.magnifyingglass", enabled: state.canZoomIn)
            Text("\(state.zoomPercent)%").font(.caption).monospacedDigit()
            ForEach(MacLiveDetailPDFTool.allCases) { tool in
                MacPDFToolPaletteButton(toolID: tool.rawValue, title: tool.title, symbol: tool.symbol,
                                        isSelected: state.tool == tool.rawValue) {
                    model.perform("tool", tool.rawValue)
                }
            }
            if state.canRemove { action("remove", "선택 주석 삭제", "trash") }
        }
        .accessibilityIdentifier("pdf.live.toolbar")
    }

    private func action(_ command: String, _ title: String, _ symbol: String, enabled: Bool = true) -> some View {
        MacPDFActionButton(title: "", symbol: symbol, identifier: "pdf.live." + command, accessibilityTitle: title) {
            model.perform(command)
        }
        .frame(width: 32, height: 30)
        .disabled(!enabled)
    }

    private func options(_ state: LiveDetailPDF.ToolbarState, tool: MacLiveDetailPDFTool, maxHeight: CGFloat) -> some View {
        MacPDFCompactOptions(maxHeight: maxHeight) {
            VStack(alignment: .leading, spacing: 10) {
                MacPDFToolOptionsHeader(title: tool.title + " 설정", symbol: tool.symbol, onClose: dismissSettings)
                switch tool {
                case .image:
                    Button("이미지 파일 가져오기", systemImage: "folder") { model.perform("image") }
                case .eraser:
                    slider("지우개 크기", command: "eraserSize", value: state.eraserSize, range: 6...100)
                case .view, .hand, .select:
                    EmptyView()
                default:
                    ColorPicker("색상", selection: Binding {
                        Self.color(state.color)
                    } set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        let hex = String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()),
                                         Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                        model.perform("color", hex)
                    }, supportsOpacity: false)
                    switch tool {
                    case .text: slider("글자 크기", command: "textSize", value: state.textSize, range: 10...48)
                    case .document, .link: EmptyView()
                    default: slider("두께", command: "lineWidth", value: state.lineWidth, range: 1...36)
                    }
                    if tool == .shape {
                        Toggle("도형 채우기", isOn: Binding(get: { state.fill }, set: { model.perform("fill", $0) }))
                        Picker("도형 종류", selection: Binding(get: { state.shape }, set: { model.perform("shape", $0) })) {
                            Text(MacPDFShape.rectangle.title).tag("rectangle")
                            Text(MacPDFShape.roundedRectangle.title).tag("rounded")
                            Text(MacPDFShape.circle.title).tag("ellipse")
                            Text(MacPDFShape.triangle.title).tag("triangle")
                            Text("화살표").tag("arrow")
                        }
                    }
                }
            }
            .padding(1)
        }
        .padding(12)
        .background(MacPDFPanelSurface(radius: 12))
        .shadow(radius: 5)
        .accessibilityIdentifier("pdf.toolOptions.panel")
        .onExitCommand(perform: dismissSettings)
    }

    private func slider(_ title: String, command: String, value: Double, range: ClosedRange<Double>) -> some View {
        MacPDFOptionSlider(title: title, value: Binding(get: { value }, set: { model.perform(command, $0) }),
                           range: range, display: "\(Int(value)) px")
    }

    private func dismissSettings() { model.perform("dismissSettings") }

    private static func color(_ hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x2563eb
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
}
