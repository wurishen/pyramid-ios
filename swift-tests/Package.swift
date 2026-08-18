// swift-tools-version:5.9
//
// Pyramid 第二阶段：SillyTavern Regex 兼容层的独立测试包。
//
// 复用 Pyramid iOS 项目的源文件（../Pyramid/Models/DisplayRegex.swift 和
// ../Pyramid/Models/SillyTavernRegexScript.swift），不复制任何源码 —— 编译的是
// Pyramid 主项目里的同一份文件，确保测试和生产代码 100% 一致。
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
            path: "../Pyramid/Models",
            exclude: [
                // MessageRenderer.swift 引用 SwiftUI + os 框架，macOS 上 SwiftUI 可用但
                // MessageRenderer 又耦合 PyramidApp 的 StorageKeys（在 DisplayRegex.swift 里
                // 内部定义）。这里只导入纯 Foundation 的两个文件：
                "MessageRenderer.swift",
                "ChatCompletionResponse.swift",
                "ChatMessage.swift",
                "ChatSession.swift",
                "Character.swift",
                "Preset.swift",
                "WorldBook.swift",
                "WorldBookEntry.swift",
                "ContextTrimMode.swift",
                "MacroExpander.swift",
            ],
            sources: [
                "DisplayRegex.swift",
                "SillyTavernRegexScript.swift",
            ]
        ),
        .testTarget(
            name: "PyramidCoreTests",
            dependencies: ["PyramidCore"],
            path: "Tests/PyramidCoreTests",
            sources: [
                "SillyTavernRegexScriptTests.swift",
            ]
        ),
    ]
)