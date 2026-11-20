#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

struct PDFDocumentIcon: Identifiable {
    let id: String
    let label: String
    var englishName: String { id.replacingOccurrences(of: ".", with: " ") }

    private init(_ id: String, _ label: String) {
        self.id = id
        self.label = label
    }

    static let defaultID = "doc.text"
    static let catalog: [Self] = [
        .init(defaultID, "문서 텍스트"), .init("doc", "파일"), .init("doc.badge.plus", "새 문서 추가"),
        .init("doc.on.doc", "복사 복제"), .init("doc.text.magnifyingglass", "문서 검색"),
        .init("folder", "폴더"), .init("folder.badge.plus", "새 폴더"),
        .init("tray", "보관함"), .init("archivebox", "아카이브 저장"), .init("paperclip", "첨부"),
        .init("book.closed", "책"), .init("book", "열린 책"), .init("bookmark", "북마크"),
        .init("note.text", "노트 메모"), .init("square.and.pencil", "편집 자유노트"),
        .init("pencil", "연필"), .init("highlighter", "형광펜"), .init("scribble", "필기"),
        .init("list.bullet", "목록 글머리"), .init("list.number", "번호 목록"),
        .init("list.bullet.clipboard", "클립보드 목록"), .init("checklist", "할 일 체크리스트"),
        .init("checkmark.seal", "인증 승인"), .init("checkmark.circle", "완료 체크"),
        .init("plus.circle", "추가"), .init("xmark.circle", "취소 삭제"),
        .init("exclamationmark.triangle", "경고 주의"), .init("info.circle", "정보 안내"),
        .init("questionmark.circle", "도움말 질문"), .init("flag", "깃발 중요"),
        .init("star", "별 즐겨찾기"), .init("heart", "하트 좋아요"), .init("pin", "핀 고정"),
        .init("bell", "벨 알림"), .init("bell.badge", "새 알림"), .init("alarm", "알람"),
        .init("timer", "타이머"), .init("stopwatch", "초시계"), .init("clock", "시간 시계"),
        .init("calendar", "달력 일정"), .init("calendar.badge.checkmark", "일정 체크"),
        .init("link", "링크 연결"), .init("point.3.connected.trianglepath.dotted", "연결 흐름"),
        .init("arrow.triangle.branch", "분기 인터페이스"), .init("arrow.triangle.merge", "병합"),
        .init("arrow.left.arrow.right", "교환 양방향"), .init("arrow.clockwise", "새로고침 갱신"),
        .init("square.and.arrow.up", "공유 업로드"), .init("square.and.arrow.down", "저장 다운로드"),
        .init("magnifyingglass", "확대경 검색"), .init("house", "홈 집"),
        .init("gearshape", "설정 톱니"), .init("slider.horizontal.3", "조정 도구"),
        .init("wand.and.stars", "마법봉 효과"), .init("sparkles", "반짝임"),
        .init("paperplane", "종이비행기 보내기"), .init("airplane", "비행기"),
        .init("bolt", "번개"), .init("flame", "불꽃"), .init("lightbulb", "아이디어 전구"),
        .init("target", "목표 타깃"), .init("globe", "지구 웹"), .init("location", "위치"),
        .init("map", "지도"), .init("person", "사용자 담당자"), .init("person.2", "팀 사용자"),
        .init("person.crop.circle", "프로필"), .init("person.badge.plus", "사용자 추가"),
        .init("bubble.left", "대화 채팅 댓글"), .init("bubble.left.and.bubble.right", "말풍선 대화"),
        .init("envelope", "메일 이메일"), .init("phone", "전화"),
        .init("photo", "사진 이미지"), .init("camera", "카메라"),
        .init("video", "비디오 동영상"), .init("play.rectangle", "재생 영상"),
        .init("mic", "마이크 음성"), .init("headphones", "헤드폰"),
        .init("rectangle.3.group", "대시보드 레이아웃"), .init("square.grid.2x2", "격자 타일"),
        .init("tablecells", "표 테이블"), .init("chart.bar", "막대 차트 그래프"),
        .init("chart.line.uptrend.xyaxis", "꺾은선 그래프 추이"), .init("chart.pie", "원형 차트"),
        .init("waveform.path.ecg", "활동 신호"), .init("desktopcomputer", "컴퓨터 PC"),
        .init("laptopcomputer", "노트북"), .init("iphone", "휴대폰 아이폰"),
        .init("server.rack", "서버"), .init("externaldrive", "드라이브 저장소"),
        .init("cylinder", "데이터베이스 DB"), .init("chevron.left.forwardslash.chevron.right", "코드 개발"),
        .init("terminal", "터미널 콘솔"), .init("network", "네트워크 인터넷"),
        .init("wifi", "와이파이"), .init("cloud", "클라우드"),
        .init("lock", "자물쇠 잠금"), .init("key", "열쇠 인증 키"),
        .init("shield", "방패 보안"), .init("shield.checkered", "보호 보안"),
        .init("cart", "장바구니 구매"), .init("creditcard", "신용카드 결제"),
        .init("wonsign.circle", "원화 비용"), .init("briefcase", "업무 가방"),
        .init("cross.case", "의료 보험"), .init("building.2", "빌딩 회사"),
        .init("hammer", "망치 작업"), .init("wrench.and.screwdriver", "공구 장비"),
        .init("scissors", "가위 자르기"), .init("trash", "휴지통 삭제"),
    ].filter {
        #if os(macOS)
        NSImage(systemSymbolName: $0.id, accessibilityDescription: nil) != nil
        #else
        UIImage(systemName: $0.id) != nil
        #endif
    }

    static let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })

    static func matching(_ query: String) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return catalog.filter { icon in
            let keywords = "\(icon.id) \(icon.englishName) \(icon.label)"
            return words.allSatisfy { keywords.localizedStandardContains(String($0)) }
        }
    }
}

struct PDFDocumentMarkerStyle: Codable, Equatable {
    private static let defaultsKey = "nf.mac.pdf.documentMarkerStyle"
    private static let recentsKey = "nf.mac.pdf.documentMarkerRecentIcons"
    var icon = PDFDocumentIcon.defaultID
    var rgb: UInt32?

    init(icon: String = PDFDocumentIcon.defaultID, rgb: UInt32? = nil) {
        self.icon = PDFDocumentIcon.byID[icon] == nil ? PDFDocumentIcon.defaultID : icon
        self.rgb = rgb.flatMap { $0 <= 0xFFFFFF ? $0 : nil }
    }

    init(query: [URLQueryItem]) {
        let name = query.first { $0.name == "markerIcon" }?.value ?? PDFDocumentIcon.defaultID
        let colorValue = query.first { $0.name == "markerColor" }?.value
        let color = colorValue.flatMap { $0.count == 6 ? UInt32($0, radix: 16) : nil }
        self.init(icon: name, rgb: color)
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if icon != PDFDocumentIcon.defaultID { items.append(.init(name: "markerIcon", value: icon)) }
        if let rgb { items.append(.init(name: "markerColor", value: String(format: "%06X", rgb))) }
        return items
    }

    var background: Color {
        rgb.map { rgb in
            let (red, green, blue) = Self.components(rgb)
            return Color(.sRGB, red: red, green: green, blue: blue)
        } ?? .accentColor
    }

    var foreground: Color {
        guard let rgb else { return .white }
        let (red, green, blue) = Self.components(rgb)
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance > 0.179 ? .black : .white
    }

    private static func components(_ rgb: UInt32) -> (Double, Double, Double) {
        (Double((rgb >> 16) & 255) / 255, Double((rgb >> 8) & 255) / 255, Double(rgb & 255) / 255)
    }

    static func rgb(_ color: Color) -> UInt32? {
        #if os(macOS)
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let (red, green, blue) = (value.redComponent, value.greenComponent, value.blueComponent)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #endif
        func component(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return component(red) << 16 | component(green) << 8 | component(blue)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), let stored = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return .init(icon: stored.icon, rgb: stored.rgb)
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    static func recentIcons(from defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: recentsKey) ?? []).filter { PDFDocumentIcon.byID[$0] != nil }
    }

    static func rememberIcon(_ icon: String, in defaults: UserDefaults = .standard) -> [String] {
        let updated = Array(([icon] + recentIcons(from: defaults).filter { $0 != icon }).prefix(12))
        defaults.set(updated, forKey: recentsKey)
        return updated
    }
}

struct PDFDocumentMarkerView: View {
    let style: PDFDocumentMarkerStyle
    let size: CGFloat

    var body: some View {
        Image(systemName: style.icon)
            .font(.system(size: max(8, size * 0.59), weight: .semibold))
            .foregroundStyle(style.foreground)
            .frame(width: size, height: size)
            .background(style.background, in: RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

struct PDFDocumentToolOptions: View {
    @Binding var style: PDFDocumentMarkerStyle
    let recent: [String]
    let onChooseIcon: (String) -> Void
    @State private var query = ""
    @State private var page = 0
    private let pageSize = 24
    private let iconColumns = [GridItem(.adaptive(minimum: 34, maximum: 48), spacing: 4)]
    private let colors: [(String, UInt32)] = [
        ("회색", 0x59616C), ("보라", 0x8653DF), ("남색", 0x405FDB), ("청록", 0x0C766F),
        ("녹색", 0x16714E), ("연두", 0x5D9200), ("노랑", 0xCB8B04), ("주황", 0xD84C05),
        ("빨강", 0xB4261D), ("분홍", 0xD8246D), ("자주", 0x7436D6), ("하늘", 0x0A8DAA),
        ("파랑", 0x265ED5), ("올리브", 0x4D760E), ("황토", 0x986007), ("갈색", 0xAC400C),
        ("진분홍", 0xB91544), ("진보라", 0x642DC0), ("차콜", 0x374251),
    ]

    private var tile: Color { .primary.opacity(0.07) }

    var body: some View {
        let results = PDFDocumentIcon.matching(query)
        let pages = max(1, (results.count + pageSize - 1) / pageSize)
        let recentIcons = recent.compactMap { PDFDocumentIcon.byID[$0] }
        VStack(alignment: .leading, spacing: 10) {
            PDFDocumentMarkerView(style: style, size: 34)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(tile, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("선택한 문서 아이콘 미리보기")
            if !recentIcons.isEmpty {
                Text("최근 사용").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                iconGrid(recentIcons)
                Divider()
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("아이콘 검색 (영문 이름 / 주요 한글명)", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("pdf.document.iconSearch")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("검색어 지우기")
                }
            }
            .padding(8)
            .background(tile, in: RoundedRectangle(cornerRadius: 6))
            if results.isEmpty {
                Text("검색 결과가 없습니다.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                iconGrid(Array(results.dropFirst(min(page, pages - 1) * pageSize).prefix(pageSize)))
                if pages > 1 {
                    HStack {
                        Button { page -= 1 } label: { Image(systemName: "chevron.left").frame(width: 26, height: 24) }
                            .disabled(page == 0).accessibilityLabel("이전 아이콘 페이지")
                        Text("\(page + 1) / \(pages)").font(.caption.monospacedDigit())
                        Button { page += 1 } label: { Image(systemName: "chevron.right").frame(width: 26, height: 24) }
                            .disabled(page + 1 >= pages).accessibilityLabel("다음 아이콘 페이지")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack {
                Text("아이콘 색상").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                ColorPicker("사용자 지정 색상", selection: Binding(get: { style.background }, set: { style.rgb = PDFDocumentMarkerStyle.rgb($0) }),
                            supportsOpacity: false)
                    .labelsHidden().accessibilityLabel("사용자 지정 아이콘 색상")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 44), spacing: 4)], spacing: 7) {
                swatch("기본 테마 색상", rgb: nil)
                ForEach(colors, id: \.1) { name, rgb in swatch(name, rgb: rgb) }
            }
        }
        .onChange(of: query) { _, _ in page = 0 }
    }

    private func iconGrid(_ icons: [PDFDocumentIcon]) -> some View {
        LazyVGrid(columns: iconColumns, spacing: 5) {
            ForEach(icons) { icon in
                Button { onChooseIcon(icon.id) } label: {
                    Image(systemName: icon.id).font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(style.icon == icon.id ? Color.accentColor.opacity(0.18) : tile,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style.icon == icon.id ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(icon.label + " (" + icon.englishName + ")")
                .accessibilityLabel(icon.label)
                .accessibilityAddTraits(style.icon == icon.id ? .isSelected : [])
            }
        }
    }

    private func swatch(_ name: String, rgb: UInt32?) -> some View {
        Button { style.rgb = rgb } label: {
            Circle()
                .fill(PDFDocumentMarkerStyle(rgb: rgb).background)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.4)))
                .overlay {
                    if style.rgb == rgb {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(PDFDocumentMarkerStyle(rgb: rgb).foreground)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(style.rgb == rgb ? .isSelected : [])
    }
}
