import Foundation

/// SillyTavern `depth_prompt` 运行时注入器（Pyramid Phase 2）。
///
/// ST depth_prompt 含义：在聊天历史的指定深度插入一条消息，或拼到 system / history 段尾。
/// - `.inChat`：把 prompt 消息插入 history 副本的 `clamp(depth, 0, history.count)` 位置
///   （depth=0 → 末条之后；depth=history.count → 首条之前；越界 clamp 到 [0, count]）。
///   **仅当 `prompt.role != .system` 才有意义** —— system 角色消息不进 history，由 caller
///   改走 `systemAppendage(prompt:)`。
/// - `.before`：拼到 system 段尾（`OpenAIClient.afterSystemText` 末尾）。内容为空时不注入。
/// - `.after`：拼到历史之后（`OpenAIClient.afterHistoryText` 末尾）。内容为空时不注入。
///
/// 注入位置遵循 ST 原义，不修改 OpenAIClient 接口（避免破坏既有调用方）。
enum DepthPromptInjector {

    /// `.inChat`：在 `history` 副本的指定深度插入 prompt 消息。
    /// `inout` 数组会被原地修改；调用方传入已裁剪 / 已宏展开的副本。
    /// `prompt.role` 必须 != .system（system 角色降级语义见上方注释）。
    static func injectInChat(history: inout [ChatMessage], prompt: CharacterDepthPrompt) {
        guard !prompt.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // system role 不走 inChat（与 ChatMessage.Role 仅 user / assistant 保持一致；
        // caller 负责把 system + .inChat 改走 systemAppendage）
        let chatRole: ChatMessage.Role
        switch prompt.role {
        case .user: chatRole = .user
        case .assistant: chatRole = .assistant
        case .system: return   // 静默 no-op；caller 应该用 systemAppendage
        }
        let clamped = max(0, min(prompt.depth, history.count))
        let message = ChatMessage(role: chatRole, content: prompt.content)
        history.insert(message, at: clamped)
    }

    /// `.before` / `.after` / (`.inChat` + role=.system) 三种共用：返回非空 system 段拼��。
    /// 任意 position 都返回非空（caller 负责按需拼到 before / after）。
    static func systemAppendage(prompt: CharacterDepthPrompt) -> String {
        guard !prompt.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return prompt.content
    }
}
