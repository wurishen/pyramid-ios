import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("apiBaseURL") var baseURL = ""
    @AppStorage("apiKey") var apiKey = ""
    @AppStorage("modelName") var modelName = ""
    @AppStorage("systemPrompt") var systemPrompt = ""
    @AppStorage("useStreaming") var useStreaming = true
    @AppStorage("worldBookEnabled") var worldBookEnabled = true
    @AppStorage("worldBookShowInjection") var showInjectionIndicator = false
    @AppStorage("showContextHint") var showContextHint = true
    @AppStorage("contextLimit") var contextLimit = 12000
    @AppStorage("compactMode") var compactMode = false
    @AppStorage("showTimestamps") var showTimestamps = true
    @AppStorage("showAvatars") var showAvatars = true

    // 上下文裁剪
    /// `.off` / `.byMessages` / `.byCharacters`。默认按消息条数（最近 50 条）。
    @AppStorage("contextTrimMode") var contextTrimModeRaw = "byMessages"
    @AppStorage("contextTrimMessages") var contextTrimMessages = 50
    @AppStorage("contextTrimCharacters") var contextTrimCharacters = 8000

    // 用户人设
    @AppStorage("userName") var userName = ""
    @AppStorage("userAvatarData") var userAvatarData = Data()
    @AppStorage("userPersona") var userPersona = ""
    @AppStorage("userPersonaInjected") var userPersonaInjected = true
    /// 若与 userName 不同，可显式指定对 AI 看到的用户名；为空则用 userName。
    @AppStorage("userDisplayName") var userDisplayName = ""

    // 渲染管线
    /// 全局「启用 Markdown 渲染」开关。预设未自覆盖时生效。
    @AppStorage("enableMarkdown") var enableMarkdown = true
    /// 全局「剥离隐藏标签」开关。默认开。
    @AppStorage("hideTagStripEnabled") var hideTagStripEnabled = true
    /// 隐藏标签列表原始文本（逗号或换行分隔）。解析失败时退回空列表（不崩溃）。
    @AppStorage("hideTagsRaw") var hideTagsRaw = "think,thinking"

    /// 解析后的隐藏标签列表。空字符串 / 空白项已过滤。
    var hideTags: [String] {
        let separators = CharacterSet(charactersIn: ",\n\r")
        return hideTagsRaw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 写入用：从标签列表反向序列化（保留逗号语法）。
    func setHideTags(_ tags: [String]) {
        hideTagsRaw = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }
}
