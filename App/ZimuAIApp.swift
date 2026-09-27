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
            MenuBarLabel()
                .environment(AppModel.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: model.pipeline.state == .running ? "captions.bubble.fill" : "captions.bubble")
    }
}
