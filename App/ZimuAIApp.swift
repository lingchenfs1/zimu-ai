import SwiftUI
import ZimuCore

@main
struct ZimuAIApp: App {
    var body: some Scene {
        MenuBarExtra(ZimuCore.appName, systemImage: "captions.bubble") {
            Button("退出 \(ZimuCore.appName)") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
