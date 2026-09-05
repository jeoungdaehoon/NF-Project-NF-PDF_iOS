import SwiftUI

@main
struct NFMacApp: App {
    @StateObject private var preferences = MacPortalPreferences()

    var body: some Scene {
        WindowGroup("노트프리") {
            MacPortalRootView()
                .environmentObject(preferences)
        }
        .defaultSize(width: 1680, height: 1050)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("웹 콘텐츠") {
                Button("화면 확대") { preferences.zoomPercent += 5 }
                    .keyboardShortcut("+", modifiers: .command)
                Button("화면 축소") { preferences.zoomPercent -= 5 }
                    .keyboardShortcut("-", modifiers: .command)
                Button("실제 크기") { preferences.zoomPercent = 100 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            MacPortalSettingsView()
                .environmentObject(preferences)
        }
    }
}
