import Foundation

/// 把 `NativeAction` 应用到一棵 `JSONValue` 树（in-place）。
///
/// **定位**：Native IR Action 的唯一执行入口；不依赖 SwiftUI。
/// `NativeIRNode.button` 上的 action 在用户点击时由 SwiftUI renderer 调用
/// `dispatch(_:to:)`，让 VariableStore / 业务层用 mutation 后的树重新
/// 投影 NativeIR —— 形成 "UI 事件 → Action → 变量改变 → 重新生成 Native IR" 闭环。
///
/// **不替角色卡赋语义**：路径即 JSON Pointer；不需要 "HP" / "好感度" 之类的业务白名单。
/// 角色卡想给"小手机电量"打 `73`，直接 `.updateVariable(path: "/小手机电量", value: 73)`。
///
/// **返回语义**：
/// - `true`  = action 被处理（已写入树 / 显式合法忽略，例如 toggle 命中非 bool）。
/// - `false` = action 未实现（`.navigate` / `.custom`）；调用方决定 fallback（toast / noop）。
struct NativeActionDispatcher {
    init() {}

    /// 应用 action 到 `tree`（in-place 写入）。
    @discardableResult
    func dispatch(_ action: NativeAction, to tree: inout JSONValue) -> Bool {
        switch action {
        case .updateVariable(let path, let value):
            do {
                try JSONPatchApplier.apply(
                    [JSONPatchOperation(op: .replace, path: path, value: value)],
                    to: &tree
                )
                return true
            } catch {
                return false
            }
        case .toggle(let path):
            // 读取 path 处的当前值；非 bool → 不处理。
            guard case .bool(let current) = readAt(tree: tree, path: path) else {
                return false
            }
            do {
                try JSONPatchApplier.apply(
                    [JSONPatchOperation(op: .replace, path: path, value: .bool(!current))],
                    to: &tree
                )
                return true
            } catch {
                return false
            }
        case .navigate, .custom:
            // 本期 renderer 不实现；返回 false 让调用方决定 fallback。
            return false
        }
    }

    /// 极简 JSON Pointer 读：仅支持 `/key` / `/a/b/c` 形态。
    /// 不解析 `~0` / `~1` —— 本 dispatcher 只消费自己刚写过的 path。
    private func readAt(tree: JSONValue, path: String) -> JSONValue? {
        guard path.hasPrefix("/") else { return nil }
        let body = String(path.dropFirst())
        if body.isEmpty { return nil }
        var current = tree
        for segment in body.split(separator: "/") {
            switch current {
            case .object(let dict):
                guard let next = dict[String(segment)] else { return nil }
                current = next
            case .array(let arr):
                guard let idx = Int(segment), idx >= 0, idx < arr.count else { return nil }
                current = arr[idx]
            default:
                return nil
            }
        }
        return current
    }
}