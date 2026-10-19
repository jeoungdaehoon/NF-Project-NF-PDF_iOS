import AppKit
import SwiftUI

enum MacPDFImageAction: String, CaseIterable {
    case replace, resetSize, rotate, flip, crop, edit, systemEdit, front, back
    var title: String {
        switch self { case .replace: "변경"; case .resetSize: "원본 크기"; case .rotate: "회전"; case .flip: "좌우 반전"; case .crop: "자르기"; case .edit: "이미지 편집"; case .systemEdit: "시스템 편집"; case .front: "최상단"; case .back: "최하단" }
    }
    var symbol: String {
        switch self { case .replace: "photo.on.rectangle"; case .resetSize: "arrow.counterclockwise"; case .rotate: "rotate.right"; case .flip: "arrow.left.and.right"; case .crop: "crop"; case .edit: "pencil.and.outline"; case .systemEdit: "macwindow"; case .front: "square.3.layers.3d.top.filled"; case .back: "square.3.layers.3d.bottom.filled" }
    }
}

enum MacPDFMenuLayout {
    static func frame(object: CGRect, viewport: CGSize, preferredWidth: CGFloat, height: CGFloat = 78) -> CGRect {
        let width = max(1, min(preferredWidth, viewport.width - 16)), h = max(1, min(height, viewport.height - 16))
        let above = object.minY - h - 16, proposedY = above >= 8 ? above : object.maxY + 16
        return CGRect(x: min(max(8, object.midX - width / 2), max(8, viewport.width - width - 8)), y: min(max(8, proposedY), max(8, viewport.height - h - 8)), width: width, height: h)
    }
}

struct MacPDFObjectMenu: View {
    @ObservedObject var state: MacPDFEditorState
    let canvasSize: CGSize
    let onImageAction: (MacPDFImageAction) -> Void
    var body: some View {
        let image = state.selection.count == 1 && state.selected?.kind == .image
        // Keep the bubble clear of the four drag-to-connect handles.
        let menuAnchor = state.connectorEnabled ? state.selectionViewRect.insetBy(dx: -44, dy: -44) : state.selectionViewRect
        let rect = MacPDFMenuLayout.frame(object: menuAnchor, viewport: canvasSize, preferredWidth: image ? 560 : 390)
        let viewport = CGRect(origin: .zero, size: canvasSize)
        Group {
            if state.selectionViewRect.intersects(viewport) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if image {
                            ForEach(MacPDFImageAction.allCases, id: \.rawValue) { action in item(action.title, action.symbol, id: action.rawValue) { onImageAction(action) } }
                        } else {
                            item("삭제", "trash", id: "delete") { state.deleteSelected() }
                            item("복제", "plus.square.on.square", id: "duplicate") { state.duplicateSelected(); state.menuVisible = true }
                            item("복사", "doc.on.doc", id: "copy") { state.copySelected() }
                            if state.selection.count == 1 {
                                item("편집", "pencil", id: "edit") {
                                    if let object = state.selected, object.kind == .text { state.canvas?.beginTextEditing(object) }
                                    else { state.optionsTool = state.tool; state.menuVisible = false }
                                }
                            }
                            item("최상단", "square.3.layers.3d.top.filled", id: "front") { state.reorderSelected(front: true) }
                            item("최하단", "square.3.layers.3d.bottom.filled", id: "back") { state.reorderSelected(front: false) }
                        }
                        item("닫기", "xmark", id: "close") { state.menuVisible = false }
                    }.padding(8)
                }
                .frame(width: rect.width, height: rect.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                .overlay(alignment: rect.minY > state.selectionViewRect.maxY ? .top : .bottom) {
                    MenuTail().fill(Color(nsColor: .controlBackgroundColor)).frame(width: 14, height: 8)
                        .rotationEffect(.degrees(rect.minY > state.selectionViewRect.maxY ? 180 : 0)).offset(y: rect.minY > state.selectionViewRect.maxY ? -7 : 7).allowsHitTesting(false)
                }
                .shadow(radius: 5).position(x: rect.midX, y: rect.midY)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }.frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.16), value: state.menuVisible)
    }
    private func item(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        MacPDFActionButton(title: title, symbol: symbol, identifier: "pdf.object.\(id)", action: action).frame(width: 50, height: 48)
    }
}

private struct MenuTail: Shape {
    func path(in rect: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); p.closeSubpath() } }
}

struct MacPDFTextAssistant: View {
    @ObservedObject var state: MacPDFEditorState
    @State private var boxOptionsVisible = false
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { state.canvas?.textUndo(redo: false) } label: { Image(systemName: "arrow.uturn.backward") }.help("텍스트 실행 취소")
                Button { state.canvas?.textUndo(redo: true) } label: { Image(systemName: "arrow.uturn.forward") }.help("텍스트 다시 실행")
                Button("서체") { state.canvas?.showFontPicker() }.accessibilityIdentifier("pdf.text.font")
                Button("−") { set(\.fontSize, max(6, state.style.fontSize - 1), "fontSize") }
                Text("\(Int(state.style.fontSize))").monospacedDigit()
                Button("+") { set(\.fontSize, min(144, state.style.fontSize + 1), "fontSize") }
                format("B", \MacPDFStyle.bold, "bold"); format("I", \MacPDFStyle.italic, "italic")
                format("U", \MacPDFStyle.underline, "underline"); format("S", \MacPDFStyle.strike, "strike")
                ColorPicker("문자", selection: color(\.stroke, "stroke"), supportsOpacity: true).fixedSize()
                ColorPicker("배경", selection: color(\.fill, "fill"), supportsOpacity: true).fixedSize()
                ColorPicker("테두리", selection: Binding(get: { Color(nsColor: state.style.textBorder?.color ?? .clear) }, set: { value in var style = state.style; style.textBorder = .init(NSColor(value)); style.width = max(1, style.width); state.setStyle(style, field: "textBorder") }), supportsOpacity: true).fixedSize()
                MacPDFActionButton(title: "테두리 설정", identifier: "pdf.text.box") { boxOptionsVisible.toggle() }.frame(width: 80, height: 28)
                Menu("정렬") { Button("왼쪽") { set(\.alignment, 0, "alignment") }; Button("가운데") { set(\.alignment, 2, "alignment") }; Button("오른쪽") { set(\.alignment, 1, "alignment") } }
                Button { state.canvas?.toggleTextLink() } label: { Image(systemName: "link") }.help("선택 URL 링크 적용·해제")
                MacPDFActionButton(title: "완료", identifier: "pdf.text.done") { state.canvas?.finishTextEditing(); state.menuVisible = true }.frame(width: 42, height: 28)
            }.buttonStyle(.borderless).padding(10)
        }.frame(height: 48).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 3)
            .overlay(alignment: .topTrailing) {
                if boxOptionsVisible {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Spacer(); MacPDFActionButton(title: "닫기", identifier: "pdf.text.box.close") { boxOptionsVisible = false }.frame(width: 42, height: 24) }
                        MacPDFTextBoxControls(state: state)
                    }.padding(14).frame(width: 260).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 5).offset(y: 56)
                }
            }
    }
    private func set<T>(_ key: WritableKeyPath<MacPDFStyle, T>, _ value: T, _ field: String) { var style = state.style; style[keyPath: key] = value; state.setStyle(style, field: field) }
    private func color(_ key: WritableKeyPath<MacPDFStyle, MacPDFRGBA>, _ field: String) -> Binding<Color> { Binding(get: { Color(nsColor: state.style[keyPath: key].color) }, set: { set(key, .init(NSColor($0)), field) }) }
    private func format(_ title: String, _ key: WritableKeyPath<MacPDFStyle, Bool>, _ field: String) -> some View {
        MacPDFActionButton(title: title, identifier: "pdf.text.\(field)") { set(key, !state.style[keyPath: key], field) }.frame(width: 24, height: 26).background(state.style[keyPath: key] ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Shared by the input assistant and the text tool's detail palette.
struct MacPDFTextBoxControls: View {
    @ObservedObject var state: MacPDFEditorState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("텍스트 박스 테두리").font(.headline)
            Stepper("두께 \(state.style.width, specifier: "%.1f") pt", value: value(\.width, field: "width"), in: 0...12, step: 0.5)
                .accessibilityIdentifier("pdf.text.border.width")
            Toggle("점선", isOn: value(\.dashed, field: "dashed"))
                .accessibilityIdentifier("pdf.text.border.dashed")
            Text("모서리 라운드 \(state.style.textCornerRadius ?? 0, specifier: "%.0f") pt")
            Slider(value: Binding(get: { state.style.textCornerRadius ?? 0 }, set: { radius in var style = state.style; style.textCornerRadius = radius; state.setStyle(style, field: "textCornerRadius") }), in: 0...48, step: 1)
                .accessibilityLabel("텍스트 박스 모서리 라운드").accessibilityIdentifier("pdf.text.border.radius")
            Text("두께 0은 테두리 없음, 라운드 0은 직각입니다.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func value<T>(_ key: WritableKeyPath<MacPDFStyle, T>, field: String) -> Binding<T> {
        Binding(get: { state.style[keyPath: key] }, set: { value in var style = state.style; style[keyPath: key] = value; state.setStyle(style, field: field) })
    }
}
