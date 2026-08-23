import XCTest
@testable import PyramidCore

/// P11: HTML + CSS → NativeIR 完整转译链路测试。
///
/// **核心断言**：
/// - `<style>...</style>` 内容被解析为 `CSSStyleSheet`，**不再**降级为 `.htmlScript(residual)`。
/// - class / tag / inline style 选择器正确匹配 CSS 规则，合并到节点上。
/// - 解析失败 / 不识别一律保留原文，**不丢一个字**。
/// - `RenderNode.htmlStyled` → `NativeIRNode.styledContainer` 桥接正确。
/// - **不**引入业务组件（无 PhoneContainer / StatusContainer / CharacterPanel）。
/// - **不**触发任何 JavaScript / 不下载任何 URL。
///
/// 这些测试用 Pyramid 内置的 cardIn 真实场景作为 fixture —— 一个酒馆 / MVU 角色卡
/// 里常见的 status panel + button + status bar 组合。
final class P11HTMLCSSTranspileTests: XCTestCase {

    // MARK: - 1. CSSParser 基础声明解析

    func test01_parseSingleColorDeclaration() {
        let sheet = CSSParser.parseSheet(".card { color: #ff0000; }")
        XCTAssertNotNil(sheet)
        XCTAssertEqual(sheet?.rules.count, 1)
        XCTAssertEqual(sheet?.rules.first?.selector, ".card")
        let decl = sheet?.rules.first?.declarations.declarations.first
        XCTAssertEqual(decl?.property, "color")
        XCTAssertEqual(decl?.value, "#ff0000")
        guard case .color(let s) = decl?.resolved else {
            return XCTFail("expected .color resolved, got \(String(describing: decl?.resolved))")
        }
        XCTAssertEqual(s, "#ff0000")
    }

    func test02_parsePaddingShorthand() {
        let sheet = CSSParser.parseSheet(".box { padding: 10px 20px; }")
        let decl = sheet?.rules.first?.declarations.declarations.first
        guard case .padding(let insets) = decl?.resolved else {
            return XCTFail("expected .padding, got \(String(describing: decl?.resolved))")
        }
        // 10px 20px → top/bottom = 10, leading/trailing = 20
        XCTAssertEqual(insets.top, 10)
        XCTAssertEqual(insets.bottom, 10)
        XCTAssertEqual(insets.leading, 20)
        XCTAssertEqual(insets.trailing, 20)
        XCTAssertEqual(insets.unit, .px)
    }

    func test03_parseBoxShadow() {
        let sheet = CSSParser.parseSheet(".card { box-shadow: 2px 2px 4px rgba(0,0,0,0.3); }")
        let decl = sheet?.rules.first?.declarations.declarations.first
        guard case .shadow(let shadows) = decl?.resolved else {
            return XCTFail("expected .shadow, got \(String(describing: decl?.resolved))")
        }
        XCTAssertEqual(shadows.count, 1)
        XCTAssertEqual(shadows.first?.offsetX, 2)
        XCTAssertEqual(shadows.first?.offsetY, 2)
        XCTAssertEqual(shadows.first?.blur, 4)
        XCTAssertEqual(shadows.first?.color, "rgba(0,0,0,0.3)")
    }

    func test04_parseCornerRadius() {
        let sheet = CSSParser.parseSheet(".card { border-radius: 12px; }")
        let decl = sheet?.rules.first?.declarations.declarations.first
        guard case .cornerRadius(let n, let u) = decl?.resolved else {
            return XCTFail("expected .cornerRadius, got \(String(describing: decl?.resolved))")
        }
        XCTAssertEqual(n, 12)
        XCTAssertEqual(u, .px)
    }

    func test05_parseTransform() {
        let sheet = CSSParser.parseSheet(".rot { transform: translateX(10px) rotate(45deg) scale(1.2); }")
        let decl = sheet?.rules.first?.declarations.declarations.first
        guard case .transform(let comps) = decl?.resolved else {
            return XCTFail("expected .transform, got \(String(describing: decl?.resolved))")
        }
        XCTAssertEqual(comps.count, 3)
        if case .translateX(let n) = comps[0] { XCTAssertEqual(n, 10) } else { XCTFail("expected translateX at 0") }
        if case .rotate(let deg) = comps[1] { XCTAssertEqual(deg, 45) } else { XCTFail("expected rotate at 1") }
        if case .scale(let n) = comps[2] { XCTAssertEqual(n, 1.2) } else { XCTFail("expected scale at 2") }
    }

    func test06_parseTransitionAndAnimationShortHand() {
        let sheet = CSSParser.parseSheet(
            ".btn { transition: opacity 0.3s ease-in 0.1s; animation: fadeIn 0.5s ease-out 1; }"
        )
        let decls = sheet?.rules.first?.declarations.declarations ?? []
        let trans = decls.first(where: { $0.property == "transition" })
        guard case .transition(let t?) = trans?.resolved else {
            return XCTFail("expected .transition, got \(String(describing: trans?.resolved))")
        }
        XCTAssertEqual(t.property, "opacity")
        XCTAssertEqual(t.durationMs, 300)
        XCTAssertEqual(t.delayMs, 100)
        XCTAssertEqual(t.curveRaw, "ease-in")

        let anim = decls.first(where: { $0.property == "animation" })
        guard case .animation(let a?) = anim?.resolved else {
            return XCTFail("expected .animation, got \(String(describing: anim?.resolved))")
        }
        XCTAssertEqual(a.name, "fadeIn")
        XCTAssertEqual(a.durationMs, 500)
        XCTAssertEqual(a.iterationCount, 1)
    }

    func test07_parseKeyframesBlock() {
        let css = """
        @keyframes fadeIn {
          from { opacity: 0; }
          to   { opacity: 1; }
        }
        """
        let sheet = CSSParser.parseSheet(css)
        XCTAssertNotNil(sheet)
        XCTAssertNotNil(sheet?.keyframes["fadein"])
        let frames = sheet?.keyframes["fadein"] ?? []
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?.percent, 0)
        XCTAssertEqual(frames.last?.percent, 100)
    }

    func test08_parseInlineStyle() {
        let style = CSSParser.parseInlineStyle("color: red; padding: 4px 8px; opacity: 0.5;")
        XCTAssertNotNil(style)
        XCTAssertEqual(style?.declarations.count, 3)
    }

    func test09_unknownDeclarationPreservesRaw() {
        // 未识别属性 → .other(property:value) 不失败
        let sheet = CSSParser.parseSheet(".x { -webkit-thing: foo; }
        ")
        XCTAssertNotNil(sheet)
        let decl = sheet?.rules.first?.declarations.declarations.first
        guard case .other(let p, let v) = decl?.resolved else {
            return XCTFail("expected .other for unrecognized property, got \(String(describing: decl?.resolved))")
        }
        XCTAssertEqual(p, "-webkit-thing")
        XCTAssertEqual(v, "foo")
    }

    // MARK: - 2. HTMLCSSTranspiler 真实 cardIn 场景

    /// 真实角色卡片段：card 容器 + 状态栏 + button。
    /// 期望：所有 <style> 块被解析为样式；容器被升级为 htmlStyled；样式声明合并 class + inline。
    func test10_cardInRealisticScenario() {
        let html = """
        <style>
        .card {
          background-color: #fff8dc;
          border-radius: 12px;
          padding: 16px;
          box-shadow: 0 2px 8px rgba(0,0,0,0.1);
          margin: 8px;
        }
        .status-bar {
          background: linear-gradient(90deg, #ff9966, #ff5e62);
          padding: 4px 12px;
          border-radius: 6px;
          color: #ffffff;
        }
        .btn {
          padding: 8px 16px;
          background-color: #4a90e2;
          color: white;
          border-radius: 4px;
          opacity: 0.95;
        }
        </style>
        <div class="card">
          <div class="status-bar">好感度: 75</div>
          <p style="color: #333333; font-size: 14px;">一段说明文本。</p>
          <button class="btn" onclick="setVariable('/hp', 100)">回血</button>
        </div>
        """
        let nodes = HTMLCSSTranspiler.transpile(html)
        XCTAssertFalse(nodes.isEmpty, "应至少产出一个节点")

        // 第一个节点应该是 outer <div class="card"> 升级后的 htmlStyled。
        guard case let .htmlStyled(tag, classNames, style, children) = nodes[0] else {
            return XCTFail("expected .htmlStyled for outer .card div, got \(nodes[0])")
        }
        XCTAssertEqual(tag, "div")
        XCTAssertEqual(classNames, ["card"])
        // 验证合并后的样式声明至少包含 color / background / padding / shadow / radius
        let props = Set(style.declarations.map { $0.property })
        XCTAssertTrue(props.contains("background-color"))
        XCTAssertTrue(props.contains("border-radius"))
        XCTAssertTrue(props.contains("padding"))
        XCTAssertTrue(props.contains("box-shadow"))
        // children 应含 status-bar + p + button
        XCTAssertGreaterThanOrEqual(children.count, 3)

        // 验证 status-bar 子节点也被升级为 htmlStyled。
        let statusBar = children.first(where: {
            if case let .htmlStyled(_, c, _, _) = $0, c.contains("status-bar") { return true }
            return false
        })
        XCTAssertNotNil(statusBar, "status-bar 节点应升级为 htmlStyled")
        guard case let .htmlStyled(_, sbClass, sbStyle, _) = statusBar else {
            return XCTFail("status-bar 类型不��配")
        }
        XCTAssertEqual(sbClass, ["status-bar"])
        let sbProps = Set(sbStyle.declarations.map { $0.property })
        XCTAssertTrue(sbProps.contains("background") || sbProps.contains("background-color"))
        XCTAssertTrue(sbProps.contains("color"))
    }

    /// Inline style 与 class 样式合并（inline last-wins）：同 property 后者覆盖前者。
    func test11_inlineOverridesClassStyle() {
        let html = """
        <style>
        .box { color: red; padding: 10px; }
        </style>
        <div class="box" style="color: blue;">test</div>
        """
        let nodes = HTMLCSSTranspiler.transpile(html)
        guard case let .htmlStyled(_, _, style, _) = nodes[0] else {
            return XCTFail("expected htmlStyled, got \(nodes[0])")
        }
        // color 应被 inline "blue" 覆盖 → 只有一条 color 声明
        let colorDecl = style.declarations.filter { $0.property == "color" }
        XCTAssertEqual(colorDecl.count, 1)
        XCTAssertEqual(colorDecl.first?.value, "blue")
        // padding 仍来自 class
        XCTAssertNotNil(style.declarations.first(where: { $0.property == "padding" }))
    }

    /// 不带 class / 不带 inline style 的 div → 走原 htmlContainer 路径（无样式）。
    func test12_unstyledDivKeepsHtmlContainer() {
        let html = "<div>plain</div>"
        let nodes = HTMLCSSTranspiler.transpile(html)
        XCTAssertEqual(nodes.count, 1)
        guard case .htmlContainer = nodes[0] else {
            return XCTFail("expected htmlContainer for unstyled div, got \(nodes[0])")
        }
    }

    /// `<style>` 块不再作为 `htmlScript(residual)` 残留 —— CSS 已转译为 stylesheet。
    func test13_styleBlockNotLeftAsResidual() {
        let html = """
        <style>.x { color: red; }</style>
        <div class="x">test</div>
        """
        let nodes = HTMLCSSTranspiler.transpile(html)
        // 不应出现形如 `<style>...</style>` 的 htmlScript residual 节点。
        for n in nodes {
            if case let .htmlScript(residual) = n {
                XCTAssertFalse(
                    residual.replacement.lowercased().contains("<style"),
                    "style 块不应残留为 htmlScript: \(residual.replacement)"
                )
            }
        }
    }

    /// 解析失败 → 走 fallback 路径（原文保留），不丢字。
    func test14_parseFailureFallbackPreservesRaw() {
        // 没有 class 匹配的 unknown element + 包含 <style>
        let html = """
        <style>.weird { whatever: maybe; }</style>
        <unknown-tag>x</unknown-tag>
        """
        let nodes = HTMLCSSTranspiler.transpile(html)
        XCTAssertFalse(nodes.isEmpty, "应保留原文节点")
        // <unknown-tag> 应被识别为 unknown → 走 htmlScript residual 路径（原文完整保留）
        let hasResidual = nodes.contains(where: {
            if case .htmlScript = $0 { return true }
            return false
        })
        XCTAssertTrue(hasResidual, "<unknown-tag> 应降级为 htmlScript residual（原文保留）")
    }

    /// 多层嵌套：outer 容器 + inner 容器各自匹配不同 class，样式独立。
    func test15_nestedStyledContainers() {
        let html = """
        <style>
        .outer { padding: 20px; background-color: #fff; }
        .inner { padding: 10px; color: #333; }
        </style>
        <div class="outer">
          <div class="inner">inner text</div>
        </div>
        """
        let nodes = HTMLCSSTranspiler.transpile(html)
        guard case let .htmlStyled(_, _, outerStyle, outerChildren) = nodes[0] else {
            return XCTFail("expected outer htmlStyled, got \(nodes[0])")
        }
        XCTAssertTrue(outerStyle.declarations.contains(where: { $0.property == "background-color" }))
        // 内层应也是 htmlStyled（独立 class 样式）
        guard case let .htmlStyled(_, _, innerStyle, _) = outerChildren[0] else {
            return XCTFail("expected inner htmlStyled, got \(outerChildren[0])")
        }
        XCTAssertTrue(innerStyle.declarations.contains(where: { $0.property == "color" }))
    }

    // MARK: - 3. 桥接：RenderNode.htmlStyled → NativeIRNode.styledContainer

    func test16_renderNodeStyledBridgesToNativeIR() {
        let style = CSSStyleDeclaration(declarations: [
            CSSDeclaration(property: "color", value: "red", resolved: .color("red")),
            CSSDeclaration(property: "padding", value: "8px", resolved: .padding(CSSEdgeInsets.all(8, .px)))
        ])
        let rn: RenderNode = .htmlStyled(tag: "div", classNames: ["card"], style: style, children: [
            .text("hello")
        ])
        let ir = RenderNodeTranspiler.transpile(rn)
        guard case let .styledContainer(tag, classNames, irStyle, irChildren) = ir else {
            return XCTFail("expected .styledContainer, got \(ir)")
        }
        XCTAssertEqual(tag, "div")
        XCTAssertEqual(classNames, ["card"])
        XCTAssertEqual(irStyle.declarations.count, 2)
        XCTAssertEqual(irChildren.count, 1)
        // children 递归桥接
        guard case .text(let s) = irChildren[0] else {
            return XCTFail("expected .text for inner, got \(irChildren[0])")
        }
        XCTAssertEqual(s, "hello")
    }

    /// CSS 解析失败 → stylesheet 为空 → .htmlContainer 不被升级（原文保留）。
    func test17_cssParseFailureNoDataLoss() {
        // malformed CSS → parseSheet 返回 nil → CSSStyleSheet.empty
        let sheet = CSSParser.parseSheet(".x {")  // 缺少闭合 }
        XCTAssertNil(sheet, "malformed CSS 应返回 nil（parseSheet 失败路径）")
        // 但 HTMLCSSTranspiler.transpile 仍然能跑：HTMLTranspiler 路径兜底
        let html = "<div class=\"x\">y</div>"
        let nodes = HTMLCSSTranspiler.transpile(html)
        XCTAssertFalse(nodes.isEmpty, "CSS 解析失败时 HTML 仍应被解析（保底）")
    }

    /// button + onclick → nativeAction 仍走 HTMLTranspiler 路径（不被 CSS 干扰）。
    func test18_buttonActionUnaffectedByCSS() {
        let html = """
        <style>.btn { padding: 4px; }</style>
        <button class="btn" onclick="setVariable('/hp', 100)">回血</button>
        """
        let nodes = HTMLCSSTranspiler.transpile(html)
        // 应至少有一个 nativeAction 节点（不被 CSS 改写）
        let hasAction = nodes.contains(where: {
            if case .nativeAction = $0 { return true }
            return false
        })
        XCTAssertTrue(hasAction, "button + onclick 应仍产出 nativeAction 节点")
    }

    /// 已知限制：后代选择器 / :hover / @media 不支持 —— 静默忽略不抛错。
    func test19_unsupportedSelectorsSilentlyIgnored() {
        let html = """
        <style>
        .parent .child { color: red; }
        .hover-target:hover { color: blue; }
        @media (max-width: 600px) { .x { color: green; } }
        </style>
        <div class="child">x</div>
        """
        // 不抛错即可 —— 后代选择器在本层不匹配，节点保持 htmlContainer。
        let nodes = HTMLCSSTranspiler.transpile(html)
        XCTAssertFalse(nodes.isEmpty)
    }

    /// `<script>` 不被 CSS 管道影响 —— 仍走 htmlScript(residual)。
    func test20_scriptBlockPreservedAsResidual() {
        let html = """
        <style>.x { color: red; }</style>
        <script>alert('hi')</script>
        """
        let nodes = HTMLCSSTranspiler.transpile(html)
        let script = nodes.first(where: {
            if case .htmlScript = $0 { return true }
            return false
        })
        XCTAssertNotNil(script, "<script> 应仍降级为 htmlScript(residual)")
    }
}
