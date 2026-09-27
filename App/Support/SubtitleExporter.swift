import AppKit
import UniformTypeIdentifiers
import ZimuCore

/// 把本次会话的字幕导出为 SRT 文件
@MainActor
enum SubtitleExporter {
    static func exportSRT(records: [SubtitleRecord], mode: SubtitleDisplayMode) {
        guard !records.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "还没有可以导出的字幕"
            alert.informativeText = "开始识别并产生字幕后再导出。"
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出字幕"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "字幕-\(formatter.string(from: Date())).srt"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = SRTFormatter.format(records, mode: mode)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
