import SwiftUI
import ZimuCore

@main
struct ZimuAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(AppModel.shared)
        } label: {
            Image(systemName: "captions.bubble")
        }
        .menuBarExtraStyle(.window)
    }
}
