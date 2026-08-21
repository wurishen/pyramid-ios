import Foundation

/// Tavern / 角色卡可识别的"原始表达"入口。
///
/// **定位**：与 `RenderNode` 平行 —— `RenderNode` 是酒馆文本经 `RenderNodeParser`
/// 切出的旧 IR；`TavernExpression` 是更上游的"原始表达"，由 Transpiler 决定
/// 怎么转成 Native IR。两个枚举互不依赖，新旧两套 pipeline 都能独立存在。
///
/// **Transpiler 第一阶段识别范围**（仅通用表达；不引入业务模板）：
/// - 文本、数值、字段、列表、容器、按钮、动作、动画、占位符
/// - 未知结构走 `.unknown` 通道；**不**丢数据、不替角色卡做业务决策
///
/// **不识别范围**（保持 strict）：
/// - HTML / CSS / JavaScript / WebView / DOM —— 任何"在 iOS 里偷偷运行一个浏览器"
///   的做法都被排除。Tavern 表达的"动画意图"只通过 `NativeAnimation` 这种轻量
///   描述结构承载；具体动画由 SwiftUI 选。
enum TavernExpression: Equatable, Sendable {
    /// statData 变量树（来自 VariableStore 当前 session）。
    case statData(JSONValue)
    /// `<status>...</status>` 文本块（P1 旧通道；Transpiler 把它当文本看待，
    /// 文本里有结构化片段就识别出来，否则全部塞进 residual）。
    case statusBlock(text: String)
    /// 已知 `.statusFields` 列表（P1/P2 中间 IR；直接转写为 container + fields）。
    case statusFields([StatusField])
    /// 已知 `.statusPlaceholder` 的 statData 树。
    case statusPlaceholder(JSONValue)
    /// 已知 `.variableUpdate` 摘要。
    case variableUpdate(appliedCount: Int, affectedPaths: [String])
    /// 纯文本片段。
    case text(String)
    /// 按钮 hint（label + 关联动作）。来自角色卡可识别的"按钮"语义。
    case buttonHint(label: String, action: NativeAction)
    /// 动画意图 hint（fade / slide / scale / transition + 可选 durationMs）。
    case animationHint(NativeAnimation)
    /// 未知 / 不识别的表达 —— 严格保留 raw 原文 + 标记原因，绝不丢数据。
    case unknown(reason: String, raw: String)
}

/// Tavern 表达 → Native IR 通用转译器。
///
/// **职责**：
/// - 识别输入表达的结构（dispatch on `TavernExpression` 的 case，**不**基于字段名 / 角色名）。
/// - 提取数据、可识别的 UI 意图、交互动作、动画意图。
/// - 转成 `NativeIRNode` 树，**不**依赖 SwiftUI / UIKit / WebView。
///
/// **明确禁止**：
/// - `if key == "HP"` / `if name == "手机"` / `if key == "好感度"` 等字段名分支。
/// - 创建 `PhoneComponent` / `ShopComponent` / `HPComponent` 等业务组件。
/// - 运行任意 JavaScript / HTML / CSS 解析。
/// - 在 renderer 反向调用 parser。
///
/// **未知结构处理**：
/// 任何识别不出的结构都走 `.unknown` 通道，Transpiler 把它包成一个 `container`：
///   - `title = "未识别"`
///   - 一个 `text` 子节点说明原因
///   - 一个 `field` 子节点保存 raw 原文
/// 保证数据不丢、UI 不崩。
enum TavernTranspiler {

    /// 把一个 Tavern 表达转成 NativeIRNode 树。
    static func transpile(_ expression: TavernExpression) -> NativeIRNode {
        switch expression {
        case .statData(let value):
            // 复用第三阶段的 projector —— 这是"数据 → IR"的通用通路。
            return NativeIRProjector.project(statData: value)

        case .statusPlaceholder(let value):
            // P3 placeholder 树 → IR；与 statData 走同一条通路。
            return NativeIRProjector.project(statData: value)

        case .statusFields(let fields):
            // 已知 fields 列表 → container + field 列表。
            // 不解析字段名 —— 每个 field 都按 "label-value 对" 渲染。
            return .container(
                title: "状态",
                children: fields.map { field in
                    .field(label: field.label, value: field.value)
                },
                animation: nil
            )

        case .statusBlock(let text):
            return transpileStatusBlock(text)

        case .variableUpdate(let count, let paths):
            return .container(
                title: "变量更新",
                children: [
                    .field(label: "applied", value: String(count)),
                    .field(label: "paths", value: paths.joined(separator: ", ")),
                ],
                animation: nil
            )

        case .text(let s):
            return .text(content: s)

        case .buttonHint(let label, let action):
            return .button(label: label, action: action)

        case .animationHint(let animation):
            // 单独的动画意图 → 用一个空 container 承载 animation；renderer 看到
            // 非 nil animation 就把子树用对应动画呈现。
            return .container(
                title: "动画",
                children: [.text(content: "[\(animation.kind)]")],
                animation: animation
            )

        case .unknown(let reason, let raw):
            // 关键：保留 raw 原文 + 标记原因；UI 不丢数据。
            return .container(
                title: "未识别",
                children: [
                    .text(content: "[\(reason)]"),
                    .field(label: "raw", value: raw),
                ],
                animation: nil
            )
        }
    }

    // MARK: - 内部

    /// `<status>...</status>` 文本块的轻量识别：
    /// - `key: value` 行 → 拆成 `field`
    /// - 空行 → 跳过
    /// - 其它字符 → 当成纯文本包成 `text`
    /// **不**基于字段名走业务分支；所有行一视同仁。
    private static func transpileStatusBlock(_ text: String) -> NativeIRNode {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var children: [NativeIRNode] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let (label, value) = splitKV(trimmed) {
                children.append(.field(label: label, value: value))
            } else {
                children.append(.text(content: String(trimmed)))
            }
        }
        if children.isEmpty {
            // 空 status 块 → unknown 通道，保留原文。
            return transpile(.unknown(reason: "empty status block", raw: text))
        }
        return .container(title: "状态", children: children, animation: nil)
    }

    /// 极简 "key: value" 分割。支持 ASCII `:` 和全角 `：`。
    /// 不解析字段名，只按字符切。
    private static func splitKV(_ line: String) -> (String, String)? {
        // Swift 把 `":"` / `"："` 字面量推断成 String —— 显式构造 Character。
        let separators: [Character] = [Character(":"), Character("：")]
        for sep in separators {
            if let idx = line.firstIndex(of: sep) {
                let label = line[..<idx].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                if !label.isEmpty, !value.isEmpty {
                    return (String(label), String(value))
                }
            }
        }
        return nil
    }
}