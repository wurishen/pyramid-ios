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
}
