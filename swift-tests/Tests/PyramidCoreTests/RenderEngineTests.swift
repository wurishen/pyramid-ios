import XCTest
@testable import PyramidCore

/// RenderEngine 8 个测试：覆盖 raw 不变 / Result Equatable / 100 次稳定 / context 切换重算等。
final class RenderEngineTests: XCTestCase {

    private func rule(_ pattern: String, _ replacement: String, enabled: Bool = true) -> DisplayRegex {
        DisplayRegex(name: pattern, pattern: pattern, replacement: replacement, enabled: enabled)
    }

    private func ctx(
        isAssistant: Bool = true,
        presetIds: [UUID] = [],
        rules: [DisplayRegex] = [],
        hideEnabled: Bool = false,
        hideTags: [String] = [],
        markdownEnabled: Bool = true
    ) -> RenderEngine.Context {
        RenderEngine.Context(
            isAssistant: isAssistant,
            presetDisplayRegexIds: presetIds,
            allDisplayRegexes: rules,
            hideTagStripEnabled: hideEnabled,
            hideTags: hideTags,
            markdownEnabled: markdownEnabled
        )
    }

    // 1. render 接受 raw 字符串作为输入
    func test1_renderAcceptsRaw() {
        let result = RenderEngine.render(raw: "Hello World", context: ctx())
        XCTAssertEqual(result.cleanedText, "Hello World")
    }

    // 2. raw 引用值不变（不被修改）
    func test2_rawUnchangedAfterRender() {
        let raw: String = "Hello World"
        let original = raw
        let c = ctx(rules: [rule("World", "Pyramid")])
        _ = RenderEngine.render(raw: raw, context: c)
        XCTAssertEqual(raw, original, "raw must not be mutated")
    }

    // 3. Result 是 Equatable struct；可独立传给视图
    func test3_resultIsEquatableAndCopyable() {
        let c = ctx()
        let r1 = RenderEngine.render(raw: "abc", context: c)
        let r2 = r1
        let r3 = RenderEngine.render(raw: "abc", context: c)
        XCTAssertEqual(r1, r2)
        XCTAssertEqual(r1, r3)
    }

    // 4. 同 (raw, context) 渲染 100 次 → cleanedText 字节相同
    func test4_stableAcrossHundredRenders() {
        let c = ctx(rules: [rule("World", "Pyramid")])
        let first = RenderEngine.render(raw: "Hello World", context: c).cleanedText
        for _ in 0..<100 {
            XCTAssertEqual(RenderEngine.render(raw: "Hello World", context: c).cleanedText, first)
        }
    }

    // 5. 同 raw 切换 rule.enabled → cleanedText 改变
    func test5_contextChangeRecomputesResult() {
        let on = ctx(rules: [rule("World", "Pyramid", enabled: true)])
        let off = ctx(rules: [rule("World", "Pyramid", enabled: false)])
        XCTAssertEqual(RenderEngine.render(raw: "Hello World", context: on).cleanedText, "Hello Pyramid")
        XCTAssertEqual(RenderEngine.render(raw: "Hello World", context: off).cleanedText, "Hello World")
    }

    // 6. 同 (raw, context) 重复调用 → cleanedText 一致
    func test6_reRenderSameInputIdenticalOutput() {
        let c = ctx()
        let a = RenderEngine.render(raw: "# Title\n\nbody", context: c)
        let b = RenderEngine.render(raw: "# Title\n\nbody", context: c)
        XCTAssertEqual(a.cleanedText, b.cleanedText)
    }

    // 7. presetDisplayRegexIds 顺序控制多条规则的执行
    func test7_presetOrderControlsExecution() {
        let r1 = rule("World", "Pyramid")
        let r2 = rule("Pyramid", "iOS")
        // preset: r1, r2 → World→Pyramid→iOS
        let c12 = ctx(presetIds: [r1.id, r2.id], rules: [r1, r2])
        XCTAssertEqual(RenderEngine.render(raw: "Hello World", context: c12).cleanedText, "Hello iOS")
        // preset: r2, r1 → Pyramid 不命中, World→Pyramid
        let c21 = ctx(presetIds: [r2.id, r1.id], rules: [r1, r2])
        XCTAssertEqual(RenderEngine.render(raw: "Hello World", context: c21).cleanedText, "Hello Pyramid")
    }

    // 8. hideTagStripEnabled=true + hideTags=["think"] → 剥离思考段
    func test8_hideTagsStripping() {
        let c = ctx(hideEnabled: true, hideTags: ["think"])
        let result = RenderEngine.render(raw: "before<think>secret</think>after", context: c)
        XCTAssertEqual(result.cleanedText, "beforeafter")
    }
}
