import Foundation

/// SillyTavern V3 `data.extensions.depth_prompt` typed 形态。
///
/// ST schema: `{role: "system"|"user", depth: Int, content: String, position?: "before"|"after"|"in-chat"}`。
/// - `role` 默认 `"system"`（多数酒馆角色卡省略）。
/// - `depth` 默认 `4`（扫描深度；0 = 仅末条后）。
/// - `position` 默认 `.inChat`（嵌入历史副本指定深度）。
///
/// 仅做字段承载；运行时注入由 `DepthPromptInjector` 在 ChatViewModel.request 路径上完成。
/// Codable round-trip 完整保留 role / depth / content / position；旧 Pyramid 角色卡无此字段 → nil。
struct CharacterDepthPrompt: Codable, Equatable, Hashable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
    }

    /// ST 文档约定的 3 个插入位置。
    /// ST 实际 JSON 值是 `"before"` / `"after"` / `"in-chat"`（带连字符）。
    enum Position: String, Codable {
        case before
        case after
        case inChat = "in-chat"
    }

    var role: Role
    var depth: Int
    var content: String
    var position: Position

    init(role: Role = .system,
         depth: Int = 4,
         content: String,
         position: Position = .inChat) {
        self.role = role
        self.depth = depth
        self.content = content
        self.position = position
    }

    /// 从 `JSONValue` 解析。任一必需字段缺失或类型错 → 返回 nil。
    /// 失败时调用方保留 `extensionsRaw.depth_prompt` 不动，避免静默丢字段。
    init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }
        // role：缺失给 .system；非 String / 未知值 → nil（保留 raw）。
        let role: Role
        if case .string(let s) = obj["role"] {
            guard let parsed = Role(rawValue: s) else { return nil }
            role = parsed
        } else if obj["role"] == nil || obj["role"] == .some(.null) {
            role = .system
        } else {
            return nil
        }
        // depth：缺失给 4；非 Int → nil。
        let depth: Int
        switch obj["depth"] {
        case .some(.int(let i)):
            depth = i
        case .some(.double(let d)):
            depth = Int(d)
        case .none, .some(.null):
            depth = 4
        default:
            return nil
        }
        // content：缺失 → nil；非 String → nil。空字符串允许（运行时由 caller 过滤）。
        guard case .string(let content) = obj["content"] else { return nil }
        // position：缺失给 .inChat；非 String / 未知值 → nil（保留 raw）。
        let position: Position
        switch obj["position"] {
        case .some(.string(let s)):
            guard let parsed = Position(rawValue: s) else { return nil }
            position = parsed
        case .none, .some(.null):
            position = .inChat
        default:
            return nil
        }
        self.init(role: role, depth: depth, content: content, position: position)
    }

    private enum CodingKeys: String, CodingKey {
        case role, depth, content, position
    }
}
