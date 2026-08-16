# Pyramid (iOS)

Pyramid 的最小原生 iOS 应用 —— 纯 SwiftUI，不依赖 WKWebView / 浏览器。

## 打开工程

1. 安装 Xcode（建议 15 及以上）。
2. `git clone` 本仓库后，双击 `Pyramid.xcodeproj`，或用 Xcode 菜单 **File → Open** 打开。
3. 选择 `Pyramid` scheme 与任意 iOS Simulator，⌘R 运行即可。
4. 首次打开若提示 scheme，选 **Pyramid**（工程内已共享 scheme，正常应直接可用）。

## 使用（v0.3）

应用包含两个 Tab：**聊天** 与 **设置**。

1. 进入 **设置**，填写：
   - `API Base URL`：OpenAI 兼容接口地址。带或不带 `/v1` 均可（如 `https://api.openai.com/v1` 或 `https://api.openai.com`），应用会自动拼接 `/chat/completions`。
   - `API Key`：可留空（适用于无需鉴权的本地服务）；填写时会以 `Authorization: Bearer <key>` 发送。
   - `模型名`：如 `gpt-4o-mini`、`qwen-plus` 等。
   - `系统提示词`：可选，每次请求会作为 `role=system` 消息发往接口。
   - `流式输出`：默认开启（SSE），关闭则一次性返回。
   - 填写即自动保存在本机（UserDefaults），无需手动保存。
2. 回到 **聊天**：
   - 左上角气泡按钮打开**会话列表**：可新建、切换、删除（左滑）会话；每个会话的消息记录独立保存，重启应用仍在。
   - 导航栏标题显示当前会话名（默认以首条用户消息自动命名）。
   - 输入消息并发送，用户与助手消息按轮次展示，助手回复来自 `chat/completions` 接口；流式模式下气泡随响应逐步更新。
3. 出错时（网络不可达、非 2xx 状态码、响应解析失败、未填 Base URL/模型名等）会在聊天列表上方显示红色错误信息。

## 功能范围

- 设置页：Base URL / API Key / 模型名 / 系统提示词，本地持久化；流式输出开关（默认开启）。
- 多会话：会话列表（新建/切换/删除），每个会话独立消息记录并本地持久化；聊天页显示当前会话。
- 聊天页：消息列表、输入框、发送；`URLSession` 请求 OpenAI 兼容 `chat/completions`，支持 `stream=true`（SSE，逐 delta 更新助手气泡）；主线程更新 UI。
- 错误提示：网络、状态码、解析失败均在界面展示。
- 不含：角色卡解析、世界书、扩展系统。

## 目录结构

```
Pyramid.xcodeproj/   Xcode 工程（含共享 scheme）
Pyramid/
  PyramidApp.swift     App 入口（@main）
  ContentView.swift    Tab 容器（聊天 / 设置）
  AppSettings.swift    API 配置（@AppStorage 本地持久化）
  Models/              消息、请求/响应、会话模型（ChatSession）
  Services/            OpenAIClient（URLSession）
  ViewModels/          ChatViewModel、ChatStore（会话持久化）
  Views/               ChatView、SettingsView、SessionListView
  Assets.xcassets/     图标与颜色资源
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
