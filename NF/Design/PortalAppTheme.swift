//
//  PortalAppTheme.swift
//  NF
//
//  Created by Codex on 8/20/26.
//

import Combine
import SwiftUI
import UIKit

/// 웹 포털에서 전달한 CSS 색상을 SwiftUI와 UIKit에서 함께 사용하는 RGBA 값으로 보관합니다.
struct PortalThemeColor: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    init?(cssValue rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "transparent" {
            self.init(red: 0, green: 0, blue: 0, alpha: 0)
            return
        }

        if value.hasPrefix("#") {
            let source = String(value.dropFirst())
            let normalized: String
            switch source.count {
            case 3:
                normalized = source.map { "\($0)\($0)" }.joined() + "ff"
            case 6:
                normalized = source + "ff"
            case 8:
                normalized = source
            default:
                return nil
            }
            guard let rgba = UInt64(normalized, radix: 16) else { return nil }
            self.init(
                red: Double((rgba >> 24) & 0xff) / 255,
                green: Double((rgba >> 16) & 0xff) / 255,
                blue: Double((rgba >> 8) & 0xff) / 255,
                alpha: Double(rgba & 0xff) / 255
            )
            return
        }

        guard (value.hasPrefix("rgb(") || value.hasPrefix("rgba(")),
              let openIndex = value.firstIndex(of: "("),
              let closeIndex = value.lastIndex(of: ")"),
              openIndex < closeIndex else { return nil }
        let components = value[value.index(after: openIndex)..<closeIndex]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard components.count == 3 || components.count == 4,
              let red = Double(components[0]),
              let green = Double(components[1]),
              let blue = Double(components[2]) else { return nil }
        let alpha = components.count == 4 ? Double(components[3]) ?? 1 : 1
        self.init(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// 포털 웹 테마를 네이티브 문서·PDF 화면에 적용하기 위한 의미 기반 색상 팔레트입니다.
struct PortalAppTheme: Codable, Equatable, Sendable {
    private static let softGrayNativeDocumentBackground = PortalThemeColor(
        red: 240.0 / 255.0,
        green: 240.0 / 255.0,
        blue: 240.0 / 255.0
    )

    let presetID: String
    let background: PortalThemeColor
    let surface: PortalThemeColor
    let sidebarBackground: PortalThemeColor?
    let foreground: PortalThemeColor
    let muted: PortalThemeColor
    let border: PortalThemeColor
    let accent: PortalThemeColor
    let usesDarkInterface: Bool

    static let `default` = PortalAppTheme(
        presetID: "default",
        background: PortalThemeColor(red: 0.098, green: 0.098, blue: 0.098),
        surface: PortalThemeColor(red: 0.125, green: 0.125, blue: 0.125),
        sidebarBackground: PortalThemeColor(red: 0.125, green: 0.125, blue: 0.125),
        foreground: PortalThemeColor(red: 0.831, green: 0.831, blue: 0.831),
        muted: PortalThemeColor(red: 0.561, green: 0.561, blue: 0.561),
        border: PortalThemeColor(red: 0.184, green: 0.184, blue: 0.184),
        accent: PortalThemeColor(red: 0.275, green: 0.404, blue: 0.925),
        usesDarkInterface: true
    )

    static let softGray = PortalAppTheme(
        presetID: "soft-gray",
        background: PortalThemeColor(red: 0.741, green: 0.741, blue: 0.741),
        surface: PortalThemeColor(red: 0.780, green: 0.780, blue: 0.780),
        sidebarBackground: PortalThemeColor(red: 0.769, green: 0.769, blue: 0.769),
        foreground: PortalThemeColor(red: 0.094, green: 0.094, blue: 0.094),
        muted: PortalThemeColor(red: 0.231, green: 0.231, blue: 0.231),
        border: PortalThemeColor(red: 0.643, green: 0.643, blue: 0.643),
        accent: PortalThemeColor(red: 0.247, green: 0.376, blue: 0.584),
        usesDarkInterface: false
    )

    init(
        presetID: String,
        background: PortalThemeColor,
        surface: PortalThemeColor,
        sidebarBackground: PortalThemeColor? = nil,
        foreground: PortalThemeColor,
        muted: PortalThemeColor,
        border: PortalThemeColor,
        accent: PortalThemeColor,
        usesDarkInterface: Bool
    ) {
        self.presetID = presetID
        self.background = background
        self.surface = surface
        self.sidebarBackground = sidebarBackground
        self.foreground = foreground
        self.muted = muted
        self.border = border
        self.accent = accent
        self.usesDarkInterface = usesDarkInterface
    }

    init?(messageBody: Any) {
        guard let payload = messageBody as? [String: Any] else { return nil }
        let presetID = (payload["presetID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
        let fallback = presetID == "soft-gray" ? Self.softGray : Self.default

        func color(_ key: String, fallbackColor: PortalThemeColor) -> PortalThemeColor {
            guard let rawValue = payload[key] as? String,
                  let parsed = PortalThemeColor(cssValue: rawValue) else { return fallbackColor }
            return parsed
        }

        let background = color("backgroundColor", fallbackColor: fallback.background)
        let colorScheme = (payload["colorScheme"] as? String)?.lowercased()
        self.init(
            presetID: presetID,
            background: background,
            surface: color("surfaceColor", fallbackColor: fallback.surface),
            sidebarBackground: color(
                "sidebarBackgroundColor",
                fallbackColor: fallback.sidebarBackground ?? fallback.surface
            ),
            foreground: color("foregroundColor", fallbackColor: fallback.foreground),
            muted: color("mutedColor", fallbackColor: fallback.muted),
            border: color("borderColor", fallbackColor: fallback.border),
            accent: color("accentColor", fallbackColor: fallback.accent),
            usesDarkInterface: colorScheme == "dark" || (colorScheme != "light" && background.relativeLuminance < 0.42)
        )
    }

    var colorScheme: ColorScheme {
        usesDarkInterface ? .dark : .light
    }

    var backgroundColor: Color { background.color }
    var documentLibraryBackgroundColor: Color {
        presetID == "soft-gray"
            ? Self.softGrayNativeDocumentBackground.color
            : background.color
    }
    var pdfWorkspaceBackgroundColor: Color {
        presetID == "soft-gray"
            ? Self.softGrayNativeDocumentBackground.color
            : background.color
    }
    var documentLibraryCardBackgroundColor: Color {
        presetID == "soft-gray" ? .clear : surface.color
    }
    var surfaceColor: Color { surface.color }
    var sidebarBackgroundColor: Color { (sidebarBackground ?? surface).color }
    var foregroundColor: Color { foreground.color }
    var mutedColor: Color { muted.color }
    var borderColor: Color { border.color }
    var accentColor: Color { accent.color }
}

/// WebView 브리지에서 수신한 테마를 앱 세션과 다음 실행에 유지합니다.
@MainActor
final class PortalAppThemeController: ObservableObject {
    @Published private(set) var theme: PortalAppTheme

    private static let storageKey = "nf.portal.native-theme.v1"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.storageKey),
           let storedTheme = try? JSONDecoder().decode(PortalAppTheme.self, from: data) {
            theme = storedTheme
        } else {
            theme = .default
        }
    }

    func apply(messageBody: Any) {
        guard let nextTheme = PortalAppTheme(messageBody: messageBody), nextTheme != theme else { return }
        theme = nextTheme
        if let data = try? JSONEncoder().encode(nextTheme) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }
}

private struct PortalAppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = PortalAppTheme.default
}

extension EnvironmentValues {
    var portalAppTheme: PortalAppTheme {
        get { self[PortalAppThemeEnvironmentKey.self] }
        set { self[PortalAppThemeEnvironmentKey.self] = newValue }
    }
}
