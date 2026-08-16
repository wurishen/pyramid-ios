# Pyramid (iOS)

Pyramid 的最小原生 iOS 工程骨架 —— 纯 SwiftUI，不依赖 WKWebView / 浏览器。

## 打开工程

1. 安装 Xcode（建议 15 及以上）。
2. `git clone` 本仓库后，双击 `Pyramid.xcodeproj`，或用 Xcode 菜单 **File → Open** 打开。
3. 选择 `Pyramid` scheme 与任意 iOS Simulator，⌘R 运行即可。
4. 首次打开若提示 scheme，选 **Pyramid**（工程内已共享 scheme，正常应直接可用）。

## v0.1 范围

- 仅空壳：App 启动后主界面显示「Pyramid」标题与版本号。
- 包含内容：SwiftUI App 生命周期、单视图 `ContentView`、App 图标/强调色资源目录。
- 不含内容：聊天、角色卡、扩展系统、任何 Web 套壳。这些属于后续版本规划。

## 目录结构

```
Pyramid.xcodeproj/   Xcode 工程（含共享 scheme）
Pyramid/
  PyramidApp.swift    App 入口（@main）
  ContentView.swift   主界面
  Assets.xcassets/    图标与颜色资源
.github/workflows/    GitHub Actions（macOS 上 xcodebuild 编译）
```

## 编译验证

本地：

```sh
xcodebuild build \
  -project Pyramid.xcodeproj \
  -scheme Pyramid \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

CI：推送到 `main` 后，GitHub Actions 会在 macOS runner 上执行同样的 `xcodebuild build`，可在仓库 **Actions** 页查看结果。
