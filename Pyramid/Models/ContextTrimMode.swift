import Foundation

/// 上下文裁剪策略。详见 docs/SPEC.md §14。
enum ContextTrimMode: String, CaseIterable, Identifiable {
    case off
    case byMessages
    case byCharacters

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "不裁剪"
        case .byMessages: return "最近 N 条消息"
        case .byCharacters: return "最近 C 字符"
        }
    }
}

#if canImport(SwiftUI)
extension AppSettings {
    var contextTrimMode: ContextTrimMode {
        get { ContextTrimMode(rawValue: contextTrimModeRaw) ?? .byMessages }
        set { contextTrimModeRaw = newValue.rawValue }
    }
}
#endif
