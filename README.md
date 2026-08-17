# Pyramid (iOS)

Pyramid 的最小原生 iOS 应用 —— 纯 SwiftUI，不依赖 WKWebView / 浏览器。

## 打开工程

1. 安装 Xcode（建议 15 及以上）。
2. `git clone` 本仓库后，双击 `Pyramid.xcodeproj`，或用 Xcode 菜单 **File → Open** 打开。
3. 选择 `Pyramid` scheme 与任意 iOS Simulator，⌘R 运行即可。
4. 首次打开若提示 scheme，选 **Pyramid**（工程内已共享 scheme，正常应直接可用）。

## 使用（v0.5）

应用为两 Tab 结构：**聊天** 与 **设置**。设置项以二级页面组织（点设置里任意行进入子页，导航栏「<」返回）。

### 设置

- **用户**：昵称（气泡里显示）+ 圆形头像（相册/相机）；可选「对 AI 显示的用户名」与人设正文，开关控制是否把用户人设注入对话。
- **角色卡**：列表 + 行内编辑（头像、名字、描述、性格、场景、系统提示词、可绑一本世界书）；支持 **JSON / PNG（PNG tEXt `chara` 块 / zlib+base64）** 导入，也支持原生命单文件或多选批量导入；导入后去重入库并提示「已导入 N 张角色卡」。
- **API 配置**：Base URL（自动拼 `/chat/completions`）、API Key（可空）、模型名、流式输出开关、超时、重试次数。
- **系统提示词**：全局值，会话未设置时作为兜底。
- **世界书**：多本世界书（「全局世界书」不可删）+ 条目增删改查；导出 / 导入（合并 or 覆盖）；开启「显示注入提示」时聊天页回复下方会显示「已注入世界书 N 条」。
- **预设**：把「模型名 / 系统提示词 / 绑定的世界书 / 启用 Markdown / 显示用正则 ID」打包成预设，会话详情里一键应用。
- **显示用正则**：作用域固定 `assistant.display.pre`，在助手原文渲染前执行；命中多条按顺序串行替换。空 pattern / 无效正则保存时即时报错。
- **隐藏标签**：逗号或换行分隔的标签名（默认 `think,thinking`），匹配 `<tag>...</tag>`（含跨行）整段剥离，仅作用于气泡渲染。
- **上下文 / 界面 / 数据管理**：上下文窗口（字符数阈值 + 超出提示）、头像 / 楼层号 / 用户消息气泡 ID 等界面开关、清空全部会话与设置。

填写即自动保存到 UserDefaults，无需手动保存。

### 角色 ↔ 会话（1:N）

- 一个角色可绑多个会话；同一角色再建新会话时自动在标题后追加 `1 / 2 / 3…`（如 `xxx` → `xxx1` → `xxx2`）。
- 角色绑定在新建时确定，会话内不提供更换入口；想换角色请到 **设置 → 角色卡** 另开新窗，或在 **会话列表**「详情」查看当前绑定。
- 三个新建入口：
  - **设置 → 角色卡**：点行直接开新聊天窗并切到聊天 Tab。
  - **聊天 Tab 长按**：弹出**悬浮气泡条**（半透明背景 + 底部 Tab 上方一行圆形气泡），点气泡 = 切会话，末尾「+」气泡 = 选角色卡建新窗，已有同角色对话时会提示「打开已有 / 仍要新建 / 取消」。
  - **会话列表**：「新建空白」按钮创建不带角色的会话。
- **删除会话**：聊天页**长按顶部角色头像**（haptic 反馈）→「删除当前会话？」alert；亦可在会话列表左滑删除。

### 聊天

- 左上角气泡按钮打开**会话列表**：可置顶 / 重命名 / 删除（左滑）或详情（详情里可改预设 / 世界书绑定 / 系统提示词 / 对 AI 显示的用户名 / 额外启用世界书）。
- 顶部角色头像 / 角色名横栏常驻；长按头像 = 删除当前会话（见上）。
- 导航栏右侧「复制全部」把整段对话拷到剪贴板，附用户头像酒馆样式。
- 输入消息并发送；流式（SSE）模式下助手气泡随响应逐步更新。停止生成按钮（红圆 stop）取消当前请求，已生成部分保留，输入文本恢复。
- **长按消息气泡** 弹出操作菜单：复制 / 编辑（多行编辑框，保存后写回并持久化）/ 重新生成（仅 AI 回复，删后续 + 重发，需确认）/ 删除（需确认）。发送中仅保留「复制」。
- **Markdown**：AI 回复原生 `AttributedString` 解析（加粗 / 斜体 / 行内代码 / 代码块 / 列表 / 可点击链接），失败降级为纯文本；用户消息保持纯文本。隐藏标签（默认 think / thinking）会先剥掉，再走显示用正则，最后 Markdown 渲染；**原始 content** 仍用于复制 / 编辑 / 重新生成 / API 发送。
- **宏**（仅作用于发送给 API 的出站文本）：`{{user}}` / `{{User}}` → 对 AI 显示的用户名，`{{char}}` / `{{Char}}` → 当前角色名。
- 错误（网络 / 超时 / 解析 / 空响应 / 未配 Base URL 等）在聊天列表上方红色横幅，含「重试」复用最近失败的用户消息。

## 功能范围

- API：OpenAI 兼容 `/v1/chat/completions`，流式（SSE）+ 整段两种模式；URLSession，主线程更新 UI；可设超时与重试。
- 世界书：多本、按 ID 三级作用域（全局启用 / 角色绑定 / 会话额外启用），关键词匹配，注入上限 20 条 / 2000 字符。
- 角色卡：CRUD、JSON / PNG 导入（含 SillyTavern 兼容）、头像（相册/相机，自动缩放到 512px JPEG）。
- 预设：模型 / 系统提示词 / 世界书绑定 / 启用 Markdown / 显示用正则 ID 一键应用到会话。
- 会话：多会话本地持久化、置顶、重命名、按角色 1:N 绑定、长按头像删除。
- 消息操作：长按菜单（复制 / 编辑 / 重新生成 / 删除）+ 流式停止 + 错误重试。
- 显示管线：原始 → 显示用正则（仅助手）→ 隐藏标签剥离 → Markdown 渲染（仅作用于气泡）。
- 宏：`{{user}}` / `{{User}}` / `{{char}}` / `{{Char}}`，仅作用于发送给 API 的文本。
- 不含：云同步、第三方渲染（WKWebView / SFSafariViewController）、正则脚本热更新。

## 目录结构

```
Pyramid.xcodeproj/   Xcode 工程（含共享 scheme）
Pyramid/
  PyramidApp.swift     App 入口（@main）
  ContentView.swift    Tab 容器（聊天 / 设置 + 长按聊天的悬浮气泡条）
  AppSettings.swift    API 配置（@AppStorage 本地持久化）
  Models/              消息、请求/响应、会话、世界书/条目、角色卡、预设、显示用正则模型
  Services/            OpenAIClient、WorldBookService（关键词匹配与注入）、Markdown 渲染
  Stores/              ChatStore、WorldBookStore、CharacterStore、PresetStore、DisplayRegexStore
  ViewModels/          ChatViewModel
  Views/               ChatView、SettingsView、SessionListView、SessionDetailView、
                       CharacterListView、WorldBookView、WorldBookEditView、
                       PresetListView、DisplayRegexListView、MarkdownTextView、…
  Assets.xcassets/     图标与颜色资源
.github/workflows/    GitHub Actions（编译检查 + archive/IPA 产物打包）
```

## 下载（CI 构建）

每次推送到 `main` 且构建成功后，GitHub Actions 会自动发布一个 **pre-release**，并把 IPA 挂到仓库 Releases 页：

👉 https://github.com/wurishen/pyramid-ios/releases

- 附件文件名：`Pyramid-unsigned.ipa`（正式导出成功时同样命名为该名）
- 标签形如 `build-<run_number>`，发布备注里写明来源 commit 与分支
- ⚠️ 均为**未签名（开发用）产物**，无法直接安装到真机；请下载后本地用 Xcode 重新签名（方法见下节），或下载同名的 Actions Artifact `.xcarchive` 在本机补签名

## 构建与打包（IPA）

应用仓库未配置签名证书（需要你的 Apple Team / 开发者证书 / 描述文件），所以 CI 产出的是**未签名（开发用）产物**，无法直接通过正常途径安装到真机。

### 当前 CI 产物（Actions Artifacts）

推送到 `main` 后，GitHub Actions 会依次执行：

1. Simulator 快速编译检查；
2. `xcodebuild archive`（`generic/platform=iOS`，`CODE_SIGNING_ALLOWED=NO`）；
3. 尝试无证书导出 IPA；CI 环境没有签名证书时导出会失败，并**自动回退**为「手动打包未签名 IPA」；
4. 上传两个 artifact：
   - `Pyramid-xcarchive-unsigned`：未签名的 `.xcarchive`
   - `Pyramid-ipa`：IPA（成功导出时为 `Pyramid.ipa`，回退时为 `Pyramid-unsigned.ipa`）
5. 发布 **GitHub Release**（pre-release，标签 `build-<run_number>`）：把 IPA 作为附件 `Pyramid-unsigned.ipa` 挂到 [Releases 页](https://github.com/wurishen/pyramid-ios/releases)，备注含来源 commit，见「下载（CI 构建）」。

> ⚠️ **当前 CI 无签名证书，产出的是未签名/开发用产物，真机安装需本地用 Xcode 签名。** 未签名 IPA 可用于验证包体结构、配合 sideload 工具自行重签名，或下载 `.xcarchive` 后在本机 Xcode 里补签名再导出。

### 用 Xcode（推荐）

1. Xcode 打开 `Pyramid.xcodeproj`；
2. 选中 `Pyramid` target → **Signing & Capabilities** → 勾选 *Automatically manage signing*，选择你的 **Team**（没有则到 Apple Developer 创建免费/付费开发者账号）；
3. 菜单 **Product → Archive**（设备连接或选择 "Any iOS Device"）；
4. 在 **Organizer** 中选中刚生成的 archive → **Distribute App** → 选择分发方式（App Store Connect / Ad Hoc / Development）→ 按向导完成。

### 命令行打包

先确认签名配置（在 Xcode 的 Signing & Capabilities 或 `project.pbxproj` 中设置 Team），然后：

```sh
xcodebuild archive \
  -project Pyramid.xcodeproj \
  -scheme Pyramid \
  -destination 'generic/platform=iOS' \
  -archivePath build/Pyramid.xcarchive

xcodebuild -exportArchive \
  -archivePath build/Pyramid.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist exportOptions.plist
```

`exportOptions.plist` 示例（按你的签名方式调整 `method` / `teamID`）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

导出产物位于 `build/export/`（`*.ipa`），可上传 App Store Connect，或通过 Xcode Organizer / Apple Configurator 安装到真机。

> **关键前提**：archive 前必须配置好有效的 **Team / 签名证书 / 描述文件**（App ID 与 Bundle ID `com.pyramid.ios` 匹配），否则无法生成能安装到真机的正式 IPA。

## 编译验证

本地：

```sh
xcodebuild build \
  -project Pyramid.xcodeproj \
  -scheme Pyramid \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

CI：推送到 `main` 后，GitHub Actions 会在 macOS runner 上执行 simulator 编译检查，并产出未签名 archive / IPA 作为 Actions Artifact（见「构建与打包（IPA）」），可在仓库 **Actions** 页查看结果。