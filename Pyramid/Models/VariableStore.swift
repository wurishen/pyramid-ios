import Foundation
import SwiftUI

/// 单条「扁平化」变量条目，用于 UI 列表渲染。
/// 来自 VariableStore 把嵌套 JSON 树按 JSON Pointer 路径拍扁的结果。
struct VariableEntry: Identifiable, Equatable, Sendable {
    /// JSON Pointer 形式的 path（与 patch 一致）。
    var path: String
    /// 显示值（字符串 / 数字 / 布尔 → 文字）。
    var displayValue: String
    var id: String { path }
}

/// 每会话一份的 MVU 变量存储。
///
/// **职责**：
/// - 新建会话用 `init_stat_data` 种子一次（同 sessionId 二次 seed 不覆盖现有值）。
/// - 收到 `JSON Patch` 列表 → 应用 → 触发 UI 刷新。
/// - 不直接暴露 JSON 树；只提供 `snapshot()` 扁平化列表 + `raw(forSession:)` 给 RenderNode 内部用。
///
/// **持久化**：每个 sessionId 一棵 `JSONValue` 树 → `UserDefaults["variableStores"]`
/// （Codable dict）。旧数据无此字段 → 视作空存储。
final class VariableStore: ObservableObject {
    /// sessionId → 该会话的 JSON 树（顶层是 `.object`）。
    @Published private var stores: [UUID: JSONValue] = [:]

    init() {
        load()
    }

    // MARK: - 种子（每会话仅一次）

    /// 该会话首次被请求 seed → 写入 initData；已有值 → 跳过（避免后续 patch 被覆盖）。
    func seedIfEmpty(sessionId: UUID, initData: [String: JSONValue]?) {
        guard stores[sessionId] == nil else { return }
        stores[sessionId] = .object(initData ?? [:])
        save()
    }

    // MARK: - Patch 应用

    /// 应用一组 RFC 6902 patch 到指定 session；op-level 失败抛错（不写脏数据）。
    /// - Returns: 应用成功的 op 数量（私有 `_` path 计入 skip）。
    @discardableResult
    func apply(_ patches: [JSONPatchOperation], to sessionId: UUID) throws -> Int {
        var tree: JSONValue
        if let existing = stores[sessionId] {
            tree = existing
        } else {
            // 没种子过 → 视作空 object，避免 patch 找不到根失败。
            tree = .object([:])
            stores[sessionId] = tree
        }
        let count = try JSONPatchApplier.apply(patches, to: &tree)
        stores[sessionId] = tree
        save()
        return count
    }

    // MARK: - 查询

    func raw(forSession sessionId: UUID) -> JSONValue {
        stores[sessionId] ?? .object([:])
    }

    // MARK: - 生命周期

    /// 删除指定 session 的变量树（ChatStore 删除会话时调用）。
    func removeSession(_ sessionId: UUID) {
        guard stores.removeValue(forKey: sessionId) != nil else { return }
        save()
    }

    func removeAll() {
        guard !stores.isEmpty else { return }
        stores.removeAll()
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.variableStores),
              let decoded = try? JSONDecoder().decode([UUID: JSONValue].self, from: data) else {
            return
        }
        stores = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stores) {
            UserDefaults.standard.set(data, forKey: StorageKeys.variableStores)
        }
    }

    private enum StorageKeys {
        static let variableStores = "variableStores"
    }
}

/// 把 JSON 树按 JSON Pointer 路径拍扁为 VariableEntry 列表的纯算法。
/// 独立 enum 让 `RenderNodeParser` 单测路径（Linux / 无 SwiftUI 依赖场景）
/// 不需要拉起整个 ObservableObject。
enum VariableStoreFlattener {
    static func snapshot(root: JSONValue) -> [VariableEntry] {
        guard case .object(let dict) = root else { return [] }
        return flatten(dict, prefix: "")
    }

    private static func flatten(_ dict: [String: JSONValue], prefix: String) -> [VariableEntry] {
        var entries: [VariableEntry] = []
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            let path = prefix.isEmpty ? "/\(key)" : "\(prefix)/\(key)"
            switch value {
            case .object(let nested):
                entries.append(contentsOf: flatten(nested, prefix: path))
            case .array:
                entries.append(VariableEntry(path: path, displayValue: "[数组]"))
            default:
                entries.append(VariableEntry(path: path, displayValue: format(value)))
            }
        }
        return entries
    }

    private static func format(_ v: JSONValue) -> String {
        switch v {
        case .null: return "—"
        case .bool(let b): return b ? "是" : "否"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array: return "[数组]"
        case .object: return "[对象]"
        }
    }
}