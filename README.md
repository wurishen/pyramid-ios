# Pyramid (iOS)

Pyramid 的最小原生 iOS 应用 —— 纯 SwiftUI，不依赖 WKWebView / 浏览器。

## 打开工程

1. 安装 Xcode（建议 15 及以上）。
2. `git clone` 本仓库后，双击 `Pyramid.xcodeproj`，或用 Xcode 菜单 **File → Open** 打开。
3. 选择 `Pyramid` scheme 与任意 iOS Simulator，⌘R 运行即可。
4. 首次打开若提示 scheme，选 **Pyramid**（工程内已共享 scheme，正常应直接可用）。

## 使用（v0.8）

应用为两 Tab 结构：**聊天** 与 **设置**。设置项以二级页面组织（点设置里任意行进入子页，导航栏「<」返回）。

> **v0.7 形态变更**：聊天页消息列表从 iMessage 风格左右气泡改为**酒馆式「回复视窗」**——每条消息是一张完整卡片（头部行 = 头像 + 名字 + 楼层号 `#N` + 时间戳；正文 = 圆角卡片），用户 / 助手靠「头像位置 + 背景色 + 描边 + 名字色」区分。Markdown 渲染改走块级 `MarkdownTextView`（段落 / 围栏代码块 / 列表）。底部 Tab 按钮不再带文字标签。
>
> **v0.7.1 新增**：渲染管线升级为 **RenderNode 架构**——`Raw → DisplayRegex → HideTags → RenderNodeParser → RenderTree → MessageCard`。模型原始输出里的 `<status>HP: 80\n好感度: 65</status>` 块会被解析成原生 SwiftUI `StatusView`（HP + 好感度面板，含 HP 颜色梯度：≥60 绿 / 30-60 橙 / <30 红），不再显示原始标签或纯文本。**长按消息卡片** 0.5s 弹出 **Render Inspector** 调试覆盖层（仅展示，不修改 raw）：原文 / 处理后 / RenderNode 树 / 命中的 DisplayRegex / 隐藏标签剥离状态。解析失败的 status 块自动降级为普通文本，不会丢内容。
>
> 设置 → 界面 新增 **界面缩放**（小 0.85 / 中 1.0 / 大 1.25，默认中），统一作用于消息卡片正文字号、楼层/时间辅助字号、头像尺寸、卡片内边距、列表间距与 Markdown 块级 padding；与「紧凑模式」叠加（先按缩放调基准，再叠加紧凑模式的间距减项）。`StatusView` 通过 `MessageCard` 调用处的 `.scaleEffect(scale)` 整体缩放，不修改内部字面量。切换档位立即生效（`@AppStorage` → SwiftUI 自动重绘）。
>
> **v0.8 新增：原生交互渲染层（变量树 + 原生控件 + 条件分支）**
> ① **变量树**：每个会话一棵 JSON 变量树（角色卡的 `initStatData` 作种子，按会话隔离并持久化）。卡片正文里的 `{{getvar::path}}` 宏在**显示期**对当前变量树实时取值渲染（大小写不敏感、空白容忍，裸名视为根级字段）；其余宏（`{{setvar}}` 等）不在此范围，原样透传。出站宏 `{{user}}` / `{{char}}` 行为不变。
> ② **原生控件**：按钮 `<NativeAction label="…" kind="updateVariable|toggle" path="/…" value="…"/>`（写入走 JSON Patch 语义）、输入框 `<NativeInput label? placeholder? path="/…"/>`、下拉选择 `<NativeSelect label? path="/…" values="v1,v2" labels?="甲,乙"/>`；`<UpdateVariable>` 块渲染为变量更新摘要面板（兼容旧 `<<UpdateVariable>>` 双尖括号拼写）。
> ③ **条件分支 `<NativeIf>`**：解析一次、**显示期求值**。两种形态——叶形态 `<NativeIf path op value?>真体[<NativeElse/>假体]</NativeIf>`；结构化形态 `<NativeIf><NativeAll|NativeAny|NativeNot>组合条件</…><NativeThen>真体</NativeThen>[<NativeElse>假体</NativeElse>]</NativeIf>`。操作符：`eq / ne / gt / gte / lt / lte / exists / notexists / truthy / isempty / nonempty`。支持任意嵌套；变量一变即重算并自动切换分支，无需重发消息或重新解析。
>
> **保真规则不变**：任何畸形 / 未配对的交互标签整段留在文本流逐字可见，绝不拆散或吞内容。长按 Inspector 的 RenderNode 树新增 condition 节点行，显示条件表达式与当前命中的分支。

### 设置

- **用户**：昵称（消息卡片头部显示）+ 圆形头像（相册/相机）；可选「对 AI 显示的用户名」与人设正文，开关控制是否把用户人设注入对话。
- **角色卡**：列表 + 行内编辑（头像、名字、描述、性格、场景、系统提示词、可绑一本世界书）；展开「**SillyTavern 字段（高级）**」折叠组可继续填默认开场白（first_mes）、备用开场白（alternate_greetings，每行一条）、对话示例（mes_example，注入系统提示词时带「[对话示例]」小标题）、创作者备注（creator_notes）、历史后指令（post_history_instructions）、标签（tags，逗号分隔）、创作者（creator）、版本号（character_version）。支持 **JSON / PNG（PNG tEXt `chara` 块 / zlib+base64）** 导入，**SillyTavern v1（根层字段）**、**v2（`data` 子对象 = chara_card_v2）** 与 **v3（`spec: chara_card_v3`）** 都自动回填以上 ST 字段 + V3 扩展：`data.character_book` 内嵌世界书自动建书并参与聊天注入（**「世界书绑定」Section** 里多了一个「启用内嵌世界书」开关 + 「打开「xxx 内嵌世界书」」按钮——开关默认开，用户可单独关掉以让该角色聊天不再注入；按钮直接进入世界书页的该书，可逐条开关 / 改内容）；`extensions.talkativeness` / `fav` / `depth_prompt` typed lift；`depth_prompt` 在聊天时按 ST 规则注入（`inChat` 插入历史 / `before` 拼 system 段 / `after` 拼 history 段）。也支持 Pyramid 原生 JSON 单文件或多选批量导入；导入后去重入库并提示「已导入 N 张角色卡」。
- **API 配置**：Base URL（可带或不带 `/v1`，自动补齐再拼 `/chat/completions`）、API Key（可空）、模型名、流式输出开关（默认开）。**超时为代码内固定值**（普通请求 60 s、流式 30 s），**失败不自动重试**——聊天页错误条带提供「重试」按钮复用最近失败的用户消息。
- **系统提示词**：全局值，会话未设置时作为兜底。
- **世界书**：多本世界书（「全局世界书」不可删）+ 条目增删改查；导出 / 导入（合并 or 覆盖）；开启「显示注入提示」时聊天页回复下方会显示「已注入世界书 N 条」。**V3 内嵌书**会自动出现在 Picker 里并挂「·内嵌·角色名」小角标；该书永远非全局启用，作用域描述里写明「内嵌于 XXX 已启用 / 已停用」+「启用 / 停用开关在设置 → 角色卡 → 编辑 → 世界书绑定」。
- **预设**：把「模型名 / 系统提示词 / 绑定的世界书 / 启用 Markdown（三态：用全局 / 开 / 关） / 显示用正则 ID / 采样参数（温度、Top P、最大输出 token）」打包成预设，会话详情里一键应用。预设里的采样参数为空时不传给接口，使用后端默认。
- **显示用正则**：作用域固定 `assistant.display.pre`，在助手原文渲染前执行；命中多条按顺序串行替换。空 pattern / 无效正则保存时即时报错。**SillyTavern 兼容**：酒馆角色卡 `data.extensions.regex_scripts` 在导入时自动解析并转成 DisplayRegex（支持 `regex / replacement / enabled / flags / placement / substituteRegex / prompt_only` 字段，详见 `docs/SPEC.md` §4.6）；转换出的条目带 `sourceCharacterId`，删除该角色时同步清理。**Phase 1 不执行 JS 沙箱**——只接受已落盘 JSON 字段。
- **渲染**：全局「启用 Markdown 渲染」开关（预设未自覆盖时生效）；「剥离隐藏标签」开关 + 隐藏标签列表（逗号或换行分隔，默认 `think,thinking`），匹配 `<tag>...</tag>`（含跨行）整段剥离，仅作用于卡片渲染。
- **上下文 / 界面 / 关于 / 备份**：上下文裁剪策略三选一（**不裁剪 / 最近 N 条消息 / 最近 C 字符**，当前用户消息始终保留），字符数估算 + 超出提示；**界面**子页集中放客户端展示类选项（**界面缩放** / 显示头像 / 显示时间戳 / 紧凑模式），渲染管线类（启用 Markdown / 剥离隐藏标签 / 显示用正则）统一在「**渲染**」子页；关于页含项目说明与 Base URL 提示；备份页支持导出 / 分享 / 导入（合并 or 覆盖），按 id 去重入库。**没有「清空全部会话与设置」的入口**——要清空可用「导入覆盖」功能。

填写即自动保存到 UserDefaults，无需手动保存。

### 角色 ↔ 会话（1:N）

- 一个角色可绑多个会话；同一角色再建新会话时自动在标题后追加 `1 / 2 / 3…`（如 `xxx` → `xxx1` → `xxx2`）。
- 角色绑定在新建时确定，会话内不提供更换入口；想换角色请到 **设置 → 角色卡** 另开新窗，或在 **会话列表**「详情」查看当前绑定。
- 三个新建入口：
  - **设置 → 角色卡**：点行直接开新聊天窗并切到聊天 Tab。
  - **聊天 Tab 长按**：弹出**悬浮气泡条**（半透明背景 + 底部 Tab 上方一行圆形气泡），点气泡 = 切会话，末尾「+」气泡 = 选角色卡建新窗，已有同角色对话时会提示「打开已有 / 仍要新建 / 取消」。
  - **会话列表**：「新建空白」按钮创建不带角色的会话。
- **开场白选择**：若当前角色存在任意开场白（`first_mes` 或任一条 `alternate_greetings`），新建会话时会先弹**开场白选择 Sheet**（默认开场白 / 备用开场白 N / 不填开场白），选定的那条会作为新会话的首条助手消息；可主动选「不填开场白」建立空白会话；没开场白的角色直接建空白会话。
- **删除会话**：聊天页**长按顶部角色头像**（haptic 反馈）→「删除当前会话？」alert；亦可在会话列表左滑删除。

### 聊天

- 左上角气泡按钮打开**会话列表**：可置顶 / 重命名 / 删除（左滑）或详情（详情里可改预设 / 世界书绑定 / 系统提示词 / 对 AI 显示的用户名 / 额外启用世界书）。
- 顶部角色头像 / 角色名横栏常驻；长按头像 = 删除当前会话（见上）。
- 导航栏右侧「复制全部」把整段对话拷到剪贴板，附用户头像酒馆样式。
- 输入消息并发送；流式（SSE）模式下助手卡片随响应逐步更新。停止生成按钮（红圆 stop）取消当前请求，已生成部分保留，输入文本恢复。
- **长按消息卡片** 弹出操作菜单：复制 / 编辑（多行编辑框，保存后写回并持久化）/ **不包含在上下文 / 包含在上下文**（切换 `isIncluded`，被排除的消息仍显示在 UI 但不进 API；当前正在请求的用户消息始终强制送入）/ 重新生成（仅 AI 回复，删后续 + 重发，需确认）/ 删除（需确认）。发送中仅保留「复制」。被排除的消息在头部 `#N` 旁显示「已排除」小标签。
- **Markdown**：AI 回复走块级 `MarkdownTextView`（段落 / 围栏代码块 / `- * +` 与 `1. 2.` 列表 / 可点击链接），用户消息保持纯文本。隐藏标签（默认 think / thinking）会先剥掉，再走显示用正则，最后 Markdown 渲染；**原始 content** 仍用于复制 / 编辑 / 重新生成 / API 发送。
- **长回复折叠**：清洗后正文超过 800 字符默认折叠到 `前 800 字 + …`，点「展开」再渲全文（仅 UI 行为，原始内容不变）。
- **宏**（仅作用于发送给 API 的出站文本）：`{{user}}` / `{{User}}` / `{{USER}}`（大小写不敏感、空格容忍）→ 对 AI 显示的用户名，`{{char}}` / `{{Char}}` → 当前角色名。
- 错误（网络 / 超时 / 解析 / 空响应 / 未配 Base URL 等）在聊天列表上方红色横幅，含「重试」复用最近失败的用户消息。

## 功能范围

- API：OpenAI 兼容 `/v1/chat/completions`，流式（SSE）+ 整段两种模式；URLSession，主线程更新 UI；可设超时与重试。
- 世界书：多本、按 ID 三级作用域（全局启用 / 角色绑定 / 会话额外启用）+ **V3 内嵌 world book**（`data.character_book` 导入时自动建书，绑定到角色，非全局启用，参与聊天注入；删除角色同步清理）。**per-character 启用开关**（`isEmbeddedWorldBookEnabled`，默认 true）在角色编辑页可单独关掉；该书在 WorldBookView Picker 上挂「·内嵌·角色名」角标 + 一键打开按钮，用户可逐条开关 / 改内容，关键词匹配，注入上限 20 条 / 2000 字符。
- 角色卡：CRUD、JSON / PNG 导入（含 SillyTavern chara_card_v1/v2/v3 兼容，回填 `first_mes / alternate_greetings / mes_example / creator_notes / post_history_instructions / tags / creator / character_version` + V3 typed lift：`talkativeness` / `isFavorite` / `depthPrompt`；V3 World Book Entry 全部 17 个新字段；`characterBookRaw` 保留字节级 round-trip），头像（相册/相机，自动缩放到 512px JPEG），存在开场白时新建会话前弹出开场白选择 Sheet。
- Context 构建：消息序列为「用户人设 → 角色（desc + personality + scenario + character.systemPrompt + `[对话示例]\n{mes_example}`）→ 会话/预设系统词 → 世界书 before/after system 条目（含 V3 内嵌书）→ 历史消息 → 世界书 after-history 条目 + 角色 `post_history_instructions`」；**V3 `depth_prompt`** 在 `expandMacros` 之后按 `(role, position)` 注入（`inChat + user/assistant` 插历史；`inChat + system` / `before` 拼 system 段；`after` 拼 history 段；空 content 不注入）；所有角色字段缺省视为空，旧数据 `decodeIfPresent` 兜底。
- Context 构建：消息序列为「用户人设 → 角色（desc + personality + scenario + character.systemPrompt + `[对话示例]\n{mes_example}`）→ 会话/预设系统词 → 世界书 before/after system 条目 → 历史消息 → 世界书 after-history 条目 + 角色 `post_history_instructions`」；所有角色字段缺省视为空，旧数据 `decodeIfPresent` 兜底。
- 预设：模型 / 系统提示词 / 世界书绑定 / 启用 Markdown / 显示用正则 ID 一键应用到会话。
- 会话：多会话本地持久化、置顶、重命名、按角色 1:N 绑定、长按头像删除。
- 消息操作：长按菜单（复制 / 编辑 / 重新生成 / 删除 / **包含在上下文切换**）+ 流式停止 + 错误重试；排除消息在 UI 显示但不进 API。
- 显示管线：原始 → 显示用正则（仅助手；含角色内嵌 ST Regex Script 自动转出的条目）→ 隐藏标签剥离 → **RenderNode 解析**（`<status>` 块转原生 `StatusView`；v0.8 起还解析 `{{getvar::}}` 宏绑定、`<UpdateVariable>`、`<NativeAction>/<NativeInput>/<NativeSelect>` 控件与 `<NativeIf>` 条件分支，见「使用」) → Markdown / 原生面板渲染（仅作用于卡片，`MarkdownTextView` 块级排版 + `StatusView` 原生面板）。
- 宏：`{{user}}` / `{{User}}` / `{{char}}` / `{{Char}}`，仅作用于发送给 API 的文本。
- 不含：云同步、第三方渲染（WKWebView / SFSafariViewController）、正则脚本热更新。
- **数据兼容**：所有「v0.6 新增字段」（Character 的 8 个 ST 字段 + ChatMessage.isIncluded）走 `init(from:) decodeIfPresent` 给默认值，旧 v0.5 JSON / UserDefaults 数据 load 时自动补齐，**无需主动迁移、不会丢任何旧数据**。

## 目录结构

```
Pyramid.xcodeproj/   Xcode 工程（含共享 scheme）
Pyramid/
  PyramidApp.swift     App 入口（@main）
  ContentView.swift    Tab 容器（聊天 / 设置 + 长按聊天的悬浮气泡条）
  AppSettings.swift    API 配置（@AppStorage 本地持久化）
   Models/              ChatMessage（含 isIncluded）、ChatSession、ChatCompletionRequest/Response、
                        Character（含 SillyTavern 兼容字段）、WorldBook/Entry、Preset、
                        DisplayRegex、ContextTrimMode、JSONValue / VariableStore（会话变量树）、
                        TavernMacro、NativeCondition、NativeIR / TavernTranspiler、
                        RenderNode / RenderNodeParser / RenderEngine（v0.7.1 渲染管线 + v0.8 原生交互层）
  Services/            OpenAIClient、WorldBookService（关键词匹配与注入）、
                       ImportSupport（原生 + SillyTavern JSON/PNG 解析）、Markdown 渲染
  Stores/              ChatStore、WorldBookStore、CharacterStore、PresetStore、DisplayRegexStore
  ViewModels/          ChatViewModel
  Views/               ChatView、SettingsView、SessionListView、SessionDetailView、
                       CharacterListView、CharacterGreetingSheet、NewSessionWithCharacterSheet、
                       WorldBookView、WorldBookEditView、PresetListView、
                       DisplayRegexListView、MarkdownTextView、MessageCard（酒馆式回复视窗）、
                       StatusView（v0.7.1 原生面板）、RenderInspectorView（v0.7.1 长按调试覆盖层）、…
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