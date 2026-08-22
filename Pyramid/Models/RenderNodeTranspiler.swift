import Foundation

/// Legacy `RenderNode` → `NativeIRNode` 通用转译器。
///
/// **定位**：让现有的 `RenderNodeParser → RenderTree` pipeline 在**不破坏**
/// legacy compat path 的前提下，也能产生 Native IR；新 / 旧 pipeline 共用
/// 同一棵 Native IR 树（同一份 UI 形态描述），任何一边消失都不影响另一边。
///
/// **与 `TavernTranspiler` 的关系**：
/// - `TavernTranspiler.transpile(TavernExpression)` —— 上游"原始表达 → IR"入口。
/// - `RenderNodeTranspiler.transpile(RenderNode)` —— 下游"legacy IR → new IR"桥接。
/// - 两条管道**互不依赖**：
///   - 旧 pipeline：`cleanedText → RenderNodeParser → RenderTree → MessageCard`。
///   - 新 pipeline：`TavernExpression → TavernTranspiler → NativeIR → 未来 renderer`。
///   - 桥接：旧 pipeline 中间产出的 `RenderTree` 通过本转译器落到 `NativeIRNode`，
///     让旧 / 新 renderer 看到同一棵 IR。**只**做桥接，不创建第二套 parser。
///
/// **硬性边界**（与 Transpiler 共享）：
/// - **不替角色卡赋语义**：键名 / 字段名一律是 data，**不**做业务判断。
/// - **不引入业务组件**：绝不创建 HPComponent / AffectionComponent / PhoneComponent 等。
/// - **不丢数据**：legacy `.status(hp:affection:)` 的两个数值都映射成独立 field，
///   labels 取自 tuple 名字（只是字符串，与行为无关）。
/// - **不修改 RenderNode**：本转译器是单向只读函数；legacy IR 形状不变。
/// - **纯函数 / Foundation only**：不依赖 SwiftUI / UIKit / WebView。
enum RenderNodeTranspiler {

    /// 单个 legacy `RenderNode` → `NativeIRNode`。
    static func transpile(_ node: RenderNode) -> NativeIRNode {
        switch node {
        case .text(let content):
            return .text(content: content)

        case .status(let hp, let affection):
            // Legacy fast-path：HP + 好感度 两个数值。
            // **不**触发"HP 颜色梯度"等业务规则 —— 旧 StatusView 的色彩规则是
            // `StatusView` 视图层职责，与 IR 层正交。落到 Native IR 后，IR 只
            // 看到两条 field，labels 与 tuple 同名以保留原始信息；renderer
            // 不会再有针对 label == "hp" 的特殊处理。
            return .container(
                title: "状态",
                children: [
                    .field(label: "hp", value: String(hp)),
                    .field(label: "affection", value: String(affection)),
                ],
                animation: nil
            )

        case .statusFields(let fields):
            // 任意 key/value 字段列表 —— labels 原样透传。
            return .container(
                title: "状态",
                children: fields.map { field in
                    .field(label: field.label, value: field.value)
                },
                animation: nil
            )

        case .statusPlaceholder(let statData):
            // 占位符走通用数据通路；与 Transpiler.statData 共用 projector。
            return NativeIRProjector.project(statData: statData)

        case .variableUpdate(let summary):
            return .container(
                title: "变量更新",
                children: [
                    .field(label: "applied", value: String(summary.appliedCount)),
                    .field(label: "paths", value: summary.affectedPaths.joined(separator: ", ")),
                ],
                animation: nil
            )

        case .deferredResidual(let residual):
            // 残留块：无法安全原生转换的显示脚本产物。**原文完整保留**为 field，
            // 不做任何业务判断 —— 与 Transpiler 未知通道同款"未识别 + raw"形态。
            return .container(
                title: "未识别",
                children: [
                    .field(label: "rule", value: residual.ruleName ?? ""),
                    .field(label: "raw", value: residual.replacement),
                ],
                animation: nil
            )

        case let .nativeAction(label, action):
            // P6 交互原语：直接落到 Native IR 的 button —— SwiftUI renderer 把
            // action 交给 NativeActionDispatcher，形成「点击 → 变量 → 新 IR」闭环。
            return .button(label: label, action: action)

        case let .nativeControl(control):
            // 通用输入控件：input / select 各自落到对应 IR case；零业务语义透传。
            switch control.kind {
            case .input:
                return .textInput(label: control.label, path: control.path, placeholder: control.placeholder)
            case .select:
                return .selection(label: control.label, path: control.path, options: control.options)
            }

        case let .macroText(segments):
            // 宏绑定文本：结构完整进入 IR（boundText）；求值由渲染层对当前变量树执行。
            return .boundText(segments: segments)

        case let .condition(node):
            // 条件分支：条件 + 双分支各自转译为 IR 子树；求值发生在渲染层。
            return .branch(
                condition: node.condition,
                whenTrue: node.whenTrue.map(transpile),
                whenFalse: node.whenFalse.map(transpile)
            )

        case let .htmlContainer(children):
            // P8 通用容器：把 children 转译成 IR list，整体再裹一层 container。
            // **不**替 children 赋业务语义 —— container 不绑定任何 Pyramid 组件名。
            return .container(
                title: nil,
                children: children.map(transpile),
                animation: nil
            )

        case let .htmlImage(src, alt):
            // P8 通用图像：透传到 NativeIR.image（**不**下载、不绑定 Character avatar）。
            return .image(src: src, alt: alt)

        case let .htmlLink(label, href):
            // P8 通用链接：透传到 NativeIR.link（**不**跳转，renderer 决定）。
            return .link(label: label, href: href)

        case let .htmlScript(residual):
            // P8 不可执行脚本：原文完整保留在 raw，**永不执行**。
            return .scriptPlaceholder(raw: residual.replacement, reason: "script block (not executed)")

        case let .htmlExternalResource(ir):
            // P8 外部资源：URL 意图记录，**永不加载**。
            return .externalResource(ir)
        }
    }

    /// 一棵 `RenderTree` → `NativeIRNode`（用 list 承载）。
    ///
    /// 上层（未来 renderer / 测试）看到的就是一个有序 list；每个元素对应
    /// 一个原 `RenderNode` 的 IR 翻译。
    static func transpile(_ tree: RenderTree) -> NativeIRNode {
        .list(items: tree.nodes.map(transpile))
    }
}