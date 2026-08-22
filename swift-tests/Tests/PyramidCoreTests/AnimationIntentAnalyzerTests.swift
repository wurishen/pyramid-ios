import XCTest
@testable import PyramidCore

/// P9 AnimationIntentAnalyzer 回归测试：
/// - 数据形状：property / from / to / duration / delay / curve / trigger；
/// - CSS transition / transform / animation / opacity / 内联 style 多声明串联；
/// - Script class-toggle / style-prop 写入；
/// - 信息保真：不可解析 / 复杂 CSS / 复杂 JS 走 nil（原文路径）；
/// - 不丢数据：rejected input 绝不静默伪造动画。
final class AnimationIntentAnalyzerTests: XCTestCase {

    // MARK: - 数据形状基础

    func test01_opacityAnimationIRDataShape() {
        let ir = AnimationIR(
            property: .opacity,
            from: 0,
            to: 1,
            durationMs: 300,
            delayMs: 0,
            curve: .easeInOut,
            trigger: .onAppear
        )
        XCTAssertEqual(ir.property, .opacity)
        XCTAssertEqual(ir.from, 0)
        XCTAssertEqual(ir.to, 1)
        XCTAssertEqual(ir.durationMs, 300)
        XCTAssertEqual(ir.delayMs, 0)
        XCTAssertEqual(ir.curve, .easeInOut)
        XCTAssertEqual(ir.trigger, .onAppear)
    }

    func test02_timingCurveEquatable() {
        XCTAssertEqual(AnimationTimingCurve.linear, AnimationTimingCurve.linear)
        XCTAssertEqual(AnimationTimingCurve.easeIn, AnimationTimingCurve.easeIn)
        XCTAssertEqual(AnimationTimingCurve.cubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0),
                       AnimationTimingCurve.cubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0))
        XCTAssertEqual(AnimationTimingCurve.spring(response: 0.35, dampingFraction: 0.78),
                       AnimationTimingCurve.spring(response: 0.35, dampingFraction: 0.78))
        XCTAssertNotEqual(AnimationTimingCurve.easeIn, AnimationTimingCurve.easeOut)
    }

    func test03_timingCurveLabel() {
        XCTAssertEqual(AnimationTimingCurve.linear.label, "linear")
        XCTAssertEqual(AnimationTimingCurve.easeIn.label, "easeIn")
        XCTAssertTrue(AnimationTimingCurve.cubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0).label.contains("cubicBezier"))
        XCTAssertTrue(AnimationTimingCurve.spring(response: 0.35, dampingFraction: 0.78).label.contains("spring"))
    }

    func test04_triggerEquatable() {
        XCTAssertEqual(AnimationTrigger.onAppear, AnimationTrigger.onAppear)
        XCTAssertEqual(AnimationTrigger.onPathChange(path: "/hp"), AnimationTrigger.onPathChange(path: "/hp"))
        XCTAssertEqual(AnimationTrigger.onAction(key: "x"), AnimationTrigger.onAction(key: "x"))
        XCTAssertNotEqual(AnimationTrigger.onAppear, AnimationTrigger.onDisappear)
        XCTAssertNotEqual(AnimationTrigger.onPathChange(path: "/a"), AnimationTrigger.onPathChange(path: "/b"))
    }

    // MARK: - CSS transition

    func test10_transitionOpacity() {
        let r = AnimationIntentAnalyzer.parseTransition("opacity 0.3s ease-in")
        XCTAssertEqual(r?.count, 1)
        guard let ir = r?.first else { return XCTFail("应有 AnimationIR") }
        XCTAssertEqual(ir.property, .opacity)
        XCTAssertEqual(ir.durationMs, 300)
        XCTAssertEqual(ir.curve, .easeIn)
    }

    func test11_transitionTransform() {
        let r = AnimationIntentAnalyzer.parseTransition("transform 0.5s ease-in-out")
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.property, .scale)
        XCTAssertEqual(r?.first?.durationMs, 500)
        XCTAssertEqual(r?.first?.curve, .easeInOut)
    }

    func test12_transitionWithDelay() {
        let r = AnimationIntentAnalyzer.parseTransition("opacity 0.3s ease-in-out 0.1s")
        XCTAssertEqual(r?.first?.durationMs, 300)
        XCTAssertEqual(r?.first?.delayMs, 100)
    }

    func test13_transitionAllRejected() {
        // `all` 不在白名单 → nil。
        XCTAssertNil(AnimationIntentAnalyzer.parseTransition("all 0.3s ease-in-out"))
    }

    func test14_transitionInvalidEasingRejected() {
        XCTAssertNil(AnimationIntentAnalyzer.parseTransition("opacity 0.3s bounce"))
    }

    func test15_transitionMissingDurationRejected() {
        XCTAssertNil(AnimationIntentAnalyzer.parseTransition("opacity ease-in-out"))
    }

    // MARK: - CSS transform

    func test20_transformScale() {
        let r = AnimationIntentAnalyzer.parseTransform("scale(0.8)")
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.property, .scale)
        XCTAssertEqual(r?.first?.to, 0.8)
    }

    func test21_transformTranslateX() {
        let r = AnimationIntentAnalyzer.parseTransform("translateX(20px)")
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.property, .offsetX)
        XCTAssertEqual(r?.first?.to, 20.0)
    }

    func test22_transformRotateDeg() {
        let r = AnimationIntentAnalyzer.parseTransform("rotate(45deg)")
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.property, .rotation)
        XCTAssertEqual(r?.first?.to, 45.0)
    }

    func test23_transformCombined() {
        let r = AnimationIntentAnalyzer.parseTransform("scale(0.5) translateX(10px)")
        XCTAssertEqual(r?.count, 2)
        XCTAssertEqual(r?[0].property, .scale)
        XCTAssertEqual(r?[0].to, 0.5)
        XCTAssertEqual(r?[1].property, .offsetX)
        XCTAssertEqual(r?[1].to, 10.0)
    }

    func test24_transformUnknownFunctionRejected() {
        XCTAssertNil(AnimationIntentAnalyzer.parseTransform("skewX(45deg)"))
    }

    func test25_transformMalformedRejected() {
        XCTAssertNil(AnimationIntentAnalyzer.parseTransform("scale(abc)"))
        XCTAssertNil(AnimationIntentAnalyzer.parseTransform("notafunc"))
    }

    // MARK: - CSS animation 关键字 keyframe

    func test30_animationFadeIn() {
        let r = AnimationIntentAnalyzer.parseAnimation("fadeIn 0.5s ease-out")
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.property, .opacity)
        XCTAssertEqual(r?.first?.from, 0)
        XCTAssertEqual(r?.first?.to, 1)
        XCTAssertEqual(r?.first?.durationMs, 500)
        XCTAssertEqual(r?.first?.curve, .easeOut)
    }

    func test31_animationFadeOut() {
        let r = AnimationIntentAnalyzer.parseAnimation("fadeOut 0.4s")
        XCTAssertEqual(r?.first?.from, 1)
        XCTAssertEqual(r?.first?.to, 0)
    }

    func test32_animationSlideIn() {
        let r = AnimationIntentAnalyzer.parseAnimation("slideIn 0.3s ease-out")
        XCTAssertEqual(r?.first?.property, .offsetX)
        XCTAssertEqual(r?.first?.from, -20)
        XCTAssertEqual(r?.first?.to, 0)
    }

    func test33_animationUnknownKeyframeRejected() {
        // 关键字命名白名单外的 keyframe → nil（不伪造动画）。
        XCTAssertNil(AnimationIntentAnalyzer.parseAnimation("pulse 0.3s"))
        XCTAssertNil(AnimationIntentAnalyzer.parseAnimation("myAnimation 0.3s"))
    }

    func test34_animationInfiniteIteration() {
        let r = AnimationIntentAnalyzer.parseAnimation("fadeIn 0.3s ease-in-out infinite")
        XCTAssertEqual(r?.first?.durationMs, 300)
        XCTAssertEqual(r?.first?.curve, .easeInOut)
    }

    // MARK: - 内联 style 多声明串联

    func test40_inlineStyleTransitionOnly() {
        let r = AnimationIntentAnalyzer.parseInlineStyle("transition: opacity 0.3s ease-in-out")
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.property, .opacity)
        XCTAssertEqual(r?.first?.durationMs, 300)
        XCTAssertEqual(r?.first?.curve, .easeInOut)
    }

    func test41_inlineStyleOpacityInert() {
        // 单纯 opacity:N 不带 timing → 返回 []（已识别但 inert），不报错。
        let r = AnimationIntentAnalyzer.parseInlineStyle("opacity: 0.5")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.count, 0)
    }

    func test42_inlineStyleMultipleDeclarations() {
        let r = AnimationIntentAnalyzer.parseInlineStyle(
            "opacity: 0; transition: opacity 0.3s ease-in-out"
        )
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.property, .opacity)
    }

    func test43_inlineStyleTransformOnly() {
        let r = AnimationIntentAnalyzer.parseInlineStyle("transform: scale(0.9)")
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.property, .scale)
        XCTAssertEqual(r?.first?.to, 0.9)
    }

    func test44_inlineStyleUnknownPropertyRejected() {
        // 未知属性 → 整段失败（保守）。调用方走 htmlScript residual。
        XCTAssertNil(AnimationIntentAnalyzer.parseInlineStyle("z-index: 999"))
        XCTAssertNil(AnimationIntentAnalyzer.parseInlineStyle("custom-prop: foo"))
    }

    func test45_inlineStyleEmptyString() {
        XCTAssertEqual(AnimationIntentAnalyzer.parseInlineStyle(""), [])
        XCTAssertEqual(AnimationIntentAnalyzer.parseInlineStyle("   "), [])
    }

    // MARK: - Script class-toggle

    func test50_classToggleShow() {
        let r = AnimationIntentAnalyzer.animation(forClassToggle: "show")
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.property, .opacity)
        XCTAssertEqual(r?.first?.from, 0)
        XCTAssertEqual(r?.first?.to, 1)
        XCTAssertEqual(r?.first?.durationMs, 300)
        if case let .onAction(key) = r?.first?.trigger ?? .onAppear {
            XCTAssertTrue(key.hasPrefix("class-toggle:"))
        } else { XCTFail("class-toggle 应配 .onAction 触发") }
    }

    func test51_classToggleFadeIn() {
        let r = AnimationIntentAnalyzer.animation(forClassToggle: "fade-in")
        XCTAssertEqual(r?.first?.property, .opacity)
    }

    func test52_classToggleUnknownRejected() {
        // 未知 class 名 → nil（不伪造动画）。
        XCTAssertNil(AnimationIntentAnalyzer.animation(forClassToggle: "my-custom-class"))
    }

    // MARK: - Script style 写入

    func test60_styleAssignmentOpacity() {
        let r = AnimationIntentAnalyzer.animation(forStyleAssignment: "opacity", value: "1")
        XCTAssertEqual(r?.property, .opacity)
        XCTAssertEqual(r?.to, 1.0)
        if case let .onAction(key) = r?.trigger ?? .onAppear {
            XCTAssertEqual(key, "style.opacity")
        } else { XCTFail("style.opacity 应配 .onAction") }
    }

    func test61_styleAssignmentOpacityWithQuotes() {
        // 解析器应能剥 `"` / `'`。
        let r = AnimationIntentAnalyzer.animation(forStyleAssignment: "opacity", value: "\"0.5\"")
        XCTAssertEqual(r?.to, 0.5)
    }

    func test62_styleAssignmentUnsupportedRejected() {
        XCTAssertNil(AnimationIntentAnalyzer.animation(forStyleAssignment: "transform", value: "scale(1)"))
        XCTAssertNil(AnimationIntentAnalyzer.animation(forStyleAssignment: "left", value: "100px"))
    }

    func test63_styleAssignmentInvalidValueRejected() {
        XCTAssertNil(AnimationIntentAnalyzer.animation(forStyleAssignment: "opacity", value: "notanumber"))
    }

    // MARK: - 信息保真边界

    func test70_complexCSSFallsToNil() {
        // CSS variables / 自定义 property → nil（不伪造动画）。
        XCTAssertNil(AnimationIntentAnalyzer.parseInlineStyle("transition: var(--anim-speed)"))
        // calc() 内含数字表达式 → nil。
        XCTAssertNil(AnimationIntentAnalyzer.parseInlineStyle("width: calc(100% - 20px)"))
    }

    func test71_complexJSFallsToNil() {
        // 复杂 JS（jQuery load / 任意 function body）不在白名单 → nil。
        // ScriptIntentAnalyzer 自身识别这类，已在 HTMLTranspiler 那边走 .htmlExternalResource。
        // 这里的 class-toggle / style 写入只接受明确写法；其它都 nil。
        XCTAssertNil(AnimationIntentAnalyzer.animation(forClassToggle: "load($('.x'))"))
    }

    func test72_malformedInputRejected() {
        XCTAssertNil(AnimationIntentAnalyzer.parseInlineStyle("transition"))
        XCTAssertNil(AnimationIntentAnalyzer.parseInlineStyle(":"))
        XCTAssertNil(AnimationIntentAnalyzer.parseTransition(""))
        XCTAssertNil(AnimationIntentAnalyzer.parseTransform(""))
        XCTAssertNil(AnimationIntentAnalyzer.parseAnimation(""))
    }

    // MARK: - HTMLTranspiler 集成（端到端）

    func test80_htmlStyleAttributeProducesAnimationNode() {
        let html = "<div style=\"transition: opacity 0.3s ease-in-out\">hi</div>"
        let nodes = HTMLTranspiler.transpile(html)
        // 期望至少 1 个 .htmlAnimation 节点 + 1 个 .htmlContainer
        let anims = nodes.compactMap { n -> AnimationIR? in
            if case let .htmlAnimation(a) = n { return a }
            return nil
        }
        XCTAssertGreaterThanOrEqual(anims.count, 1)
        XCTAssertEqual(anims.first?.property, .opacity)
        XCTAssertEqual(anims.first?.durationMs, 300)

        let hasContainer = nodes.contains { if case .htmlContainer = $0 { return true } else { return false } }
        XCTAssertTrue(hasContainer)
    }

    func test81_htmlUnknownStyleFallsToResidual() {
        // 不可解析的 style → 不挂 animation，保留正常 container。
        let html = "<div style=\"z-index: 999\">hi</div>"
        let nodes = HTMLTranspiler.transpile(html)
        // 整段标签不被拒为 htmlScript residual —— 保持原样（htmlContainer）。
        let hasContainer = nodes.contains { if case .htmlContainer = $0 { return true } else { return false } }
        XCTAssertTrue(hasContainer)
        let hasAnim = nodes.contains { if case .htmlAnimation = $0 { return true } else { return false } }
        XCTAssertFalse(hasAnim)
    }

    func test82_htmlNoStyleNoAnimation() {
        let html = "<div>hi</div>"
        let nodes = HTMLTranspiler.transpile(html)
        let hasAnim = nodes.contains { if case .htmlAnimation = $0 { return true } else { return false } }
        XCTAssertFalse(hasAnim)
    }

    // MARK: - RenderNode → NativeIR 桥接

    func test90_htmlAnimationTranspilesToText() {
        let node = RenderNode.htmlAnimation(
            AnimationIR(property: .opacity, from: 0, to: 1, durationMs: 300)
        )
        let ir = RenderNodeTranspiler.transpile(node)
        if case let .text(s) = ir {
            XCTAssertTrue(s.contains("anim"))
        } else { XCTFail(".htmlAnimation 桥接应得 .text") }
    }
}