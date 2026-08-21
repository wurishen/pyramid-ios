import Foundation

/// 把 `stat_data` JSONValue 树投影为 `NativeIRNode` 树（Tavern → Native iOS 第三层）。
///
/// **定位**：与 `NativeDisplayModelProjector` 平行、互不依赖。旧 pipeline
/// （DisplayBlock → MessageCard）继续走兼容性路径；新 pipeline（NativeIRNode
/// → 未来 SwiftUI renderer）由本 projector 驱动。
///
/// **硬性边界**：
/// - 纯函数：不读 VariableStore 全局单例；输入由调用方传入。
/// - 不抛错：异常路径走 fallback text；不写 UI。
/// - **不替角色卡赋语义**：键名（HP / 好感度 / 金币 / 小手机电量 / 催眠程度 …）
///   都不影响投影分支。`{value, max}` 这种**数据形状**才决定是否产生 `.progress`；
///   字段名只用于 label 透传，**不**触发任何固定业务组件。
enum NativeIRProjector {
    /// 根 container 标题。文档约定：整个 `stat_data` 包成 `container("状态", children)`。
    static let rootTitle = "状态"

    /// 把一棵 `stat_data` 树投影为 `NativeIRNode` 树（外层是 `container`）。
    static func project(statData: JSONValue) -> NativeIRNode {
        let children = projectRoot(statData: statData)
        return .container(title: rootTitle, children: children, animation: nil)
    }

    /// 把一棵 `stat_data` 树的根级 children 投影为有序 `NativeIRNode` 列表。
    ///
    /// 空 / 非 object 输入 → 返回占位 text，让 UI 不空白。
    static func projectRoot(statData: JSONValue) -> [NativeIRNode] {
        guard case .object(let dict) = statData else {
            return [.text(content: "[\(rootTitle) 等待变量]")]
        }
        var out: [NativeIRNode] = []
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            if isInternalKey(key) { continue }
            if let node = projectValue(key: key, value: value) {
                out.append(node)
            }
        }
        if out.isEmpty {
            return [.text(content: "[\(rootTitle) 等待变量]")]
        }
        return out
    }

    // MARK: - 内部

    /// MVU 内部元信息键 / 临时缓存键。命中即整棵子树跳过。
    /// 与 `NativeDisplayModelProjector.isInternalKey` 同步（保持旧 / 新 pipeline 行为一致）。
    private static func isInternalKey(_ key: String) -> Bool {
        switch key {
        case "$meta", "$arrayMeta", "$internal", "display_data", "delta_data":
            return true
        default:
            return false
        }
    }

    /// 单值 → 原语。**键名只用于 label，不影响分支决策**。
    private static func projectValue(key: String, value: JSONValue) -> NativeIRNode? {
        switch value {
        case .null:
            return nil
        case .bool(let b):
            return .field(label: key, value: b ? "true" : "false")
        case .int(let i):
            return .number(value: Double(i), label: key)
        case .double(let d):
            return .number(value: d, label: key)
        case .string(let s):
            if s.count > 30 {
                return .text(content: "\(key): \(s)")
            }
            return .field(label: key, value: s)
        case .array(let arr):
            // 全部 scalar → list；含 object / 嵌套 → 退化为 field（保留原文）。
            let allScalar = arr.allSatisfy { v in
                switch v {
                case .null, .bool, .int, .double, .string: return true
                default: return false
                }
            }
            if allScalar {
                let items: [NativeIRNode] = arr.compactMap { projectValue(key: "", value: $0) }
                return .list(items: items)
            }
            return .field(label: key, value: "[嵌套数组]")
        case .object(let dict):
            // 数据形状识别：`{value, max}` 显式对 → progress；否则 container 递归。
            // 这是**形状**判断，不是字段名判断 —— Pyramid 不因名字叫 HP / 好感度
            // 就升级。角色卡想给"小手机电量"加进度条，应明确写 `{value, max}`。
            if let progress = tryProjectProgress(key: key, dict: dict) {
                return progress
            }
            let children: [NativeIRNode] = dict.sorted(by: { $0.key < $1.key })
                .compactMap { (k, v) in isInternalKey(k) ? nil : projectValue(key: k, value: v) }
            return .container(title: key, children: children, animation: nil)
        }
    }

    /// 把 `{ "value": <num>, "max": <num?> }` 这种显式形态识别为 `.progress`。
    /// 仅识别**数据形状**，不依赖键名是否叫 HP / 好感度。
    private static func tryProjectProgress(key: String, dict: [String: JSONValue]) -> NativeIRNode? {
        guard let v = dict["value"], let value = asDouble(v) else { return nil }
        // 必须有 `value` 字段；`max` 可选（nil → UI 不画上限）。
        let max: Double? = dict["max"].flatMap(asDouble)
        return .progress(label: key, value: value, max: max)
    }

    private static func asDouble(_ v: JSONValue) -> Double? {
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
}