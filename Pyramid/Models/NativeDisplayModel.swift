import Foundation

/// Pyramid 1→2 投影层的输出 —— 把 `stat_data` 变量树纯函数投影为可渲染原语。
///
/// **设计目标**：
/// - 纯 Foundation 依赖，无 SwiftUI，方便 Linux SPM 单测驱动。
/// - 三个原语类别互斥：`blocks`（可渲染）/ `residual`（无法映射但不丢）。
/// - `version` 字段为后续 1→2→3 阶段预留契约位（本期固定 1）。
///
/// **映射依据**：`docs/ST_TO_NATIVE_MAPPING.md` §4.2 / §4.3 + `docs/ST_FALLBACK_RULES.md` §4。
/// 不依赖任何角色名 / 卡面路径 / 脚本名特判。
struct NativeDisplayModel: Equatable, Sendable {
    /// 输出契约版本。本期固定 1；后续版本提升时上层 UI 可据此分支。
    var version: Int = 1
    /// 可渲染的 `DisplayBlock` 顺序列表。
    var blocks: [DisplayBlock] = []
    /// 无法映射到 `DisplayBlock` 但保留原文 + 路径的字段，供 UI 在折叠面板里展开。
    var residual: [ResidualField] = []
}

/// 可渲染原语（封闭枚举，本期不增删）。
///
/// 选型理由：与 `docs/ST_TO_NATIVE_MAPPING.md` §4.2 表格中的 9 种原语一一对应；
/// `tag` 取 `tag(label, value?)` 双参形式 —— 既覆盖 `tag("是否下雨", value)`（bool 全带 value）
/// 又覆盖 `tag("苹果")`（数组元素 value 为 nil）。
enum DisplayBlock: Equatable, Sendable {
    /// 纯文本片段（最长 10000 字由 UI 层掐，超过走折叠；本层不掐）。
    case text(String)
    /// 数值（可带可选 label）。label = `nil` → 纯数字；label = `"金币"` → "50 (金币)"。
    case number(value: Double, label: String?)
    /// 进度条 / 数值条。`max == nil` → UI 不画 100% 标线。
    case bar(label: String, value: Double, max: Double?, kind: BarKind)
    /// 短标签 / 胶囊。`value == nil` → 数组元素风格；`value == "true"/"false"` → bool 风格。
    case tag(label: String, value: String?)
    /// label-value 对（最朴素呈现）。
    case field(label: String, value: String)
    /// 带标题的扁平分组（数组 → 多个 tag）。
    case section(label: String, content: [DisplayBlock])
    /// 嵌套分组（递归）。`title` 取自父对象的 key。
    case group(title: String, children: [DisplayBlock])
}

/// 进度条类型。`ratio` 留给后续 talkativeness 之类的 0–1 比例字段（卡元数据，stat_data 暂未用到）。
enum BarKind: String, Equatable, Sendable {
    case hp
    case affection
    case ratio
    case generic
}

/// 无法映射到 `DisplayBlock` 但保留原文的字段。`path` 留空时表示整棵树根级降级。
struct ResidualField: Equatable, Sendable {
    var path: String?
    var rawText: String
    /// 可选降级原因（测试断言用；UI 显示时统一转为"展开原文"）。
    var reason: String?
}