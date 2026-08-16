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
}
