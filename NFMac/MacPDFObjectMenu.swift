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
    static func frame(object: CGRect, viewport: CGSize, preferredWidth: CGFloat, height: CGFloat = 54) -> CGRect {
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
        let menuAnchor = state.connectorEnabled ? state.selectionViewRect.insetBy(dx: -44, dy: -44) : state.selectionViewRect
        let rect = MacPDFMenuLayout.frame(object: menuAnchor, viewport: canvasSize,
                                         preferredWidth: 250, height: image ? 390 : 280)
        let viewport = CGRect(origin: .zero, size: canvasSize)
        Group {
            if state.selectionViewRect.intersects(viewport) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if image {
                            imageActions("이미지", [.replace, .crop, .rotate, .flip, .resetSize])
                            imageActions("편집", [.edit, .systemEdit])
                            imageActions("쌓는 순서", [.front, .back])
                        } else {
                            if state.selection.count == 1 {
                                item("편집", "pencil", id: "edit") {
                                    if let object = state.selected, object.kind == .text { state.canvas?.beginTextEditing(object) }
                                    else { state.optionsTool = state.tool; state.menuVisible = false }
                                }
                            }
                            item("복사", "doc.on.doc", id: "copy") { state.copySelected() }
                            item("복제", "plus.square.on.square", id: "duplicate") { state.duplicateSelected(); state.menuVisible = true }
                            section("쌓는 순서")
                            item("최상단", "square.3.layers.3d.top.filled", id: "front") { state.reorderSelected(front: true) }
                            item("최하단", "square.3.layers.3d.bottom.filled", id: "back") { state.reorderSelected(front: false) }
                            Divider()
                            item("삭제", "trash", id: "delete") { state.deleteSelected() }
                        }
                        item("닫기", "xmark", id: "close") { state.menuVisible = false }
                    }
                    .padding(8)
                }
                .frame(width: rect.width, height: rect.height)
                .background(MacPDFPanelSurface(radius: 10))
                .shadow(radius: 5)
                .position(x: rect.midX, y: rect.midY)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.16), value: state.menuVisible)
    }

    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func imageActions(_ title: String, _ actions: [MacPDFImageAction]) -> some View {
        Group {
            section(title)
            ForEach(actions, id: \.rawValue) { action in
                item(action.title, action.symbol, id: action.rawValue) { onImageAction(action) }
            }
        }
    }

    private func item(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        MacPDFActionButton(title: title, symbol: symbol, identifier: "pdf.object.\(id)", inline: true, action: action)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 6)
    }
}

struct MacPDFPanelSurface: View {
    var radius: CGFloat = 10

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        shape.fill(Color(nsColor: .windowBackgroundColor))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

struct MacPDFTextAssistant: View {
    @ObservedObject var state: MacPDFEditorState
    @State private var boxOptionsVisible = false
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
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
                ColorPicker("테두리", selection: Binding(get: { Color(nsColor: state.style.textBorder?.color ?? .clear) }, set: { value in var style = state.style; style.textBorder = .init(NSColor(value)); if style.width == 0 { style.width = 0.5 }; state.setStyle(style, field: "textBorder") }), supportsOpacity: true).fixedSize()
                MacPDFActionButton(title: "테두리 설정", identifier: "pdf.text.box") { boxOptionsVisible.toggle() }.frame(width: 80, height: 28)
                Picker("정렬", selection: Binding(get: { state.style.alignment }, set: { set(\.alignment, $0, "alignment") })) {
                    Text("왼쪽").tag(0); Text("가운데").tag(2); Text("오른쪽").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button { state.canvas?.toggleTextLink() } label: { Image(systemName: "link") }.help("선택 URL 링크 적용·해제")
                MacPDFActionButton(title: "완료", identifier: "pdf.text.done") { state.canvas?.finishTextEditing(); state.menuVisible = true }.frame(width: 42, height: 28)
            }.buttonStyle(.borderless).padding(10)
        }.frame(height: 48).background(MacPDFPanelSurface(radius: 12)).shadow(radius: 3)
            .overlay(alignment: .topTrailing) {
                if boxOptionsVisible {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("테두리 설정").font(.headline); Spacer(); MacPDFActionButton(title: "닫기", identifier: "pdf.text.box.close") {
                            boxOptionsVisible = false
                            DispatchQueue.main.async { if let input = state.canvas?.activeTextView { input.window?.makeFirstResponder(input) } }
                        }.frame(width: 42, height: 24) }
                        MacPDFTextPreview(style: state.style)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        MacPDFTextBoxControls(state: state)
                    }.padding(12).frame(width: 260).background(MacPDFPanelSurface(radius: 12)).shadow(radius: 5).offset(y: 56)
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
        VStack(alignment: .leading, spacing: 12) {
            Stepper("두께 \(state.style.width, specifier: "%.1f") pt", value: value(\.width, field: "width"), in: 0...12, step: 0.5)
                .accessibilityIdentifier("pdf.text.border.width")
            MacPDFActionButton(title: "점선", identifier: "pdf.text.border.dashed", checked: state.style.dashed) {
                value(\.dashed, field: "dashed").wrappedValue.toggle()
            }
            .frame(height: 22)
            HStack {
                Text("모서리 라운드")
                Slider(value: Binding(get: { state.style.textCornerRadius ?? 0 }, set: { radius in var style = state.style; style.textCornerRadius = radius; state.setStyle(style, field: "textCornerRadius") }), in: 0...48, step: 1)
                    .accessibilityLabel("텍스트 박스 모서리 라운드").accessibilityIdentifier("pdf.text.border.radius")
                Text("\(state.style.textCornerRadius ?? 0, specifier: "%.0f") pt")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Text("두께 0은 테두리 없음, 라운드 0은 직각입니다.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func value<T>(_ key: WritableKeyPath<MacPDFStyle, T>, field: String) -> Binding<T> {
        Binding(get: { state.style[keyPath: key] }, set: { value in var style = state.style; style[keyPath: key] = value; state.setStyle(style, field: field) })
    }
}

struct MacPDFTextPreview: View {
    let style: MacPDFStyle

    var body: some View {
        Text("텍스트 박스")
            .font(.custom(style.fontName, size: min(28, max(11, style.fontSize))))
            .bold(style.bold).italic(style.italic).underline(style.underline).strikethrough(style.strike)
            .foregroundStyle(Color(nsColor: style.stroke.color))
            .frame(maxWidth: 190, alignment: style.alignment == 2 ? .center : style.alignment == 1 ? .trailing : .leading)
            .padding(6)
            .background(Color(nsColor: style.fill.color), in: RoundedRectangle(cornerRadius: style.textCornerRadius ?? 0))
            .overlay {
                RoundedRectangle(cornerRadius: style.textCornerRadius ?? 0)
                    .strokeBorder(Color(nsColor: style.textBorder?.color ?? .clear),
                                  style: StrokeStyle(lineWidth: min(6, style.width), dash: style.dashed ? [4, 3] : []))
            }
            .accessibilityHidden(true)
    }
}
