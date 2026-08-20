// swift-tools-version:5.9
//
// Pyramid 第二阶段：SillyTavern Regex 兼容层的独立测试包。
//
// 复用 Pyramid iOS 项目的源文件（DisplayRegex.swift + SillyTavernRegexScript.swift），
// 通过 Sources/PyramidCore/ 下的 symlink 指回 Pyramid/Models/ —— 测试和生产
// 用同一份源码，零拷贝。
//
// 目标平台 macOS：SillyTavernRegexScript 是纯 Foundation 代码（不需要 SwiftUI / UIKit），
// 因此可以脱离 iOS Simulator 在 `swift test` 里跑。

import PackageDescription

let package = Package(
    name: "PyramidCoreTests",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "PyramidCore",
            path: "Sources/PyramidCore"
        ),
        .testTarget(
            name: "PyramidCoreTests",
            dependencies: ["PyramidCore"],
            path: "Tests/PyramidCoreTests",
            sources: [
                "SillyTavernRegexScriptTests.swift",
                "MessageRendererChainTests.swift",
                "RenderEngineTests.swift",
                "RenderNodeParserTests.swift",
                "CharacterV3ImportTests.swift",
                "V3WorldBookEntryTests.swift",
                "CharacterExtensionsLiftTests.swift",
                "DepthPromptInjectionTests.swift",
                "EmbeddedWorldBookToggleTests.swift",
                "JSONPatchTests.swift",
                "NativeTranspileFixtureTests.swift",
            ]
        ),
    ]
)