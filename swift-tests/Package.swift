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
            path: "Sources/PyramidCore",
            swiftSettings: [
                // SPM 编译时定义；iOS app 的 Xcode build 不受影响（不同 invocation）。
                // 配合源码里的 `#if canImport(...) && !PYRAMID_SPM_BUILD` 守卫，
                // 让 SPM 编译排除 iOS-only 代码（AppSettings / ChatStore 等 SPM target 里没有）。
                .define("PYRAMID_SPM_BUILD")
            ]
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
                "P3TranspileProtocolTests.swift",
                "NativeDisplayModelTests.swift",
                "EmbeddedWorldBookParseTests.swift",
                "StatDataSeedProjectionTests.swift",
                "WorldBookServiceTests.swift",
                "MacroExpanderTests.swift",
                "ContextTrimModeTests.swift",
                "BackupServiceTests.swift",
                "PromptOnlyRegexTests.swift",
                "TavernTranspilerTests.swift",
                "TavernMacroTests.swift",
                "TavernConditionTests.swift",
                "DeferredDisplayRegexTests.swift",
                "TavernChainIntegrationTests.swift",
                "HTMLTranspilerTests.swift",
            ]
        ),
    ]
)