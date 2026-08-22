import Foundation

// P10 收口：把 P9 `AnimationIR.trigger`（onPathChange / onAction）反向调度到
// SwiftUI 运行时。
//
// **定位**：Foundation-only 的 ObservableObject，是 AnimationIR trigger 与
// VariableStore / NativeAction 既有数据流之间的**唯一**桥梁 —— 不引入第二套
// 状态系统、不执行脚本。SwiftUI 侧（NativeView）把它产生的 token 喂给
// `TriggeredAnimModifier`，token 变化 → from→to 重放。
//
// **触发语义**：
// - `.onPathChange(path)` —— `storeDidChange(tree:)` 对比 watched path 的值，
//   变化 → 该 path 的 token +1（复用 JSONValue Equatable，无轮询、无定时器）。
// - `.onAction(key)` —— 交互控件成功 apply 后调用 `fire(action)`；key 匹配规则：
//     `.updateVariable` → "updateVariable"；`.toggle` → "toggle"；
//     `.custom(key: k)` → k；`.navigate` → 无 key。
//   脚本派生 key（`class-toggle:*` / `style.opacity`）在原生运行时**没有生产者**
//   （Pyramid 永不执行脚本）—— 它们作为 IR 数据保真保留，只是不触发。
//
// `.onAppear` / `.onDisappear` 不经过本协调器：出现/消失动画由 SwiftUI
// transition 语义承担（与 P9 renderer 一致）。

/// 从 NativeIRNode 树收集 AnimationIR（含嵌套 list / container / branch 双臂），
/// 以及同级 sidecar 配对（`.animation` 修饰其后的第一个非 animation 兄弟）。
enum NativeIRAnimationPlanner {

    /// 同级配对结果：一个待渲染节点 + 挂在它身上的动画列表（按出现顺序）。
    struct SiblingGroup: Equatable, Sendable {
        var node: NativeIRNode
        var animations: [AnimationIR]
    }

    /// 树内全部 AnimationIR（先序遍历）。
    static func collect(in node: NativeIRNode) -> [AnimationIR] {
        var out: [AnimationIR] = []
        walk(node, into: &out)
        return out
    }

    /// 把有序兄弟列表按「连续 .animation → 归附下一个非 animation 节点」分组。
    /// 尾部悬空（后面没有节点）的 sidecar 不产生渲染组 —— IR 数据仍在原树中，信息不丢。
    static func group(_ items: [NativeIRNode]) -> [SiblingGroup] {
        var groups: [SiblingGroup] = []
        var pending: [AnimationIR] = []
        for item in items {
            if case let .animation(anim) = item {
                pending.append(anim)
                continue
            }
            groups.append(SiblingGroup(node: item, animations: pending))
            pending = []
        }
        return groups
    }

    private static func walk(_ node: NativeIRNode, into out: inout [AnimationIR]) {
        switch node {
        case .animation(let anim):
            out.append(anim)
        case .list(let items):
            for i in items { walk(i, into: &out) }
        case .container(_, let children, _):
            for c in children { walk(c, into: &out) }
        case .branch(_, let whenTrue, let whenFalse):
            for n in whenTrue { walk(n, into: &out) }
            for n in whenFalse { walk(n, into: &out) }
        default:
            break
        }
    }
}

/// AnimationIR trigger ↔ 运行时事件之间的 token 协调器（详见文件头注释）。
final class AnimationTriggerCoordinator: ObservableObject {

    /// watched path → 当前 token（值每变化一次 +1）。@Published 让挂了
    /// TriggeredAnimModifier 的视图随 token 重算。
    @Published private(set) var pathTokens: [String: Int] = [:]
    /// action key → 当前 token（每次匹配的 fire +1）。
    @Published private(set) var actionTokens: [String: Int] = [:]

    private var lastPathValues: [String: JSONValue] = [:]

    /// 注册要跟踪的动画集合，并对当前树做初始快照（快照当次不算变化）。
    /// 可重复调用（重新挂载 / 树重建时）；已存在的 token 计数保持不变。
    func watch(_ animations: [AnimationIR], initialTree: JSONValue) {
        let reader = NativeActionDispatcher()
        for anim in animations {
            switch anim.trigger {
            case .onPathChange(let path):
                if pathTokens[path] == nil {
                    pathTokens[path] = 0
                    // 缺失路径归一成 .null —— 「不存在 → 仍不存在」不算变化。
                    lastPathValues[path] = reader.value(at: path, in: initialTree) ?? .null
                }
            case .onAction(let key):
                if actionTokens[key] == nil { actionTokens[key] = 0 }
            case .onAppear, .onDisappear:
                break
            }
        }
    }

    /// VariableStore 变化后调用：对比所有 watched path，变化 → token +1 并刷新快照。
    func storeDidChange(tree: JSONValue) {
        guard !pathTokens.isEmpty else { return }
        let reader = NativeActionDispatcher()
        // 先快照 key 集合 —— 避免遍历期间原地改字典（只改已存在 key 的值，快照最稳）。
        let paths = Array(pathTokens.keys)
        for path in paths {
            let current = reader.value(at: path, in: tree) ?? .null
            if current != lastPathValues[path] {
                lastPathValues[path] = current
                pathTokens[path] = (pathTokens[path] ?? 0) + 1
            }
        }
    }

    /// 交互控件成功 apply 一个 NativeAction 后调用：按 key 匹配规则 bump 对应 token。
    func fire(_ action: NativeAction) {
        for key in Self.keys(for: action) {
            actionTokens[key] = (actionTokens[key] ?? 0) + 1
        }
    }

    /// 给定 trigger 的当前 token；`.onAppear` / `.onDisappear` 不归本协调器管 → nil。
    func token(for trigger: AnimationTrigger) -> AnyHashable? {
        switch trigger {
        case .onPathChange(let path):
            return AnyHashable(pathTokens[path] ?? 0)
        case .onAction(let key):
            return AnyHashable(actionTokens[key] ?? 0)
        case .onAppear, .onDisappear:
            return nil
        }
    }

    /// NativeAction → 触发的 action key 集合（见文件头注释的匹配规则）。
    static func keys(for action: NativeAction) -> [String] {
        switch action {
        case .updateVariable:
            return ["updateVariable"]
        case .toggle:
            return ["toggle"]
        case .custom(let key, _):
            return [key]
        case .navigate:
            return []
        }
    }
}
