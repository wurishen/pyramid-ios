# Fixtures

这是**显示层转译协议（native transpile protocol）的测试夹具**，不是可玩的角色卡 / 人物档案。

## 用途

驱动 Pyramid 原生渲染管线在 iOS / SPM 测试里把酒馆风格占位符 / 状态栏 / MVU JSON Patch / 显示用正则**转译**为 `RenderNode` 树 + MVU `JSON Patch` 指令。夹具只覆盖协议层字段（`first_mes` / `regex_scripts` / `sample_messages` / `init_stat_data` / `mvu_output_contract`），**不包含任何真实角色卡 / 头像 / 描述 / 人设正文**。

## 硬性边界

Pyramid 是纯原生 iOS Swift 应用 —— 设计目标彻底摆脱 SillyTavern 浏览器运行环境。夹具里**禁止**且测试断言会拒绝：

- **禁止 WebView / WKWebView**：夹具不依赖 JS 沙箱渲染。
- **禁止执行远程 HTML / JS**：`regex_scripts` 的 `markdownOnly` 替换若产物形如 `$('body').load(...)` 之类的远程副作用脚本，**测试必须跳过并断言 iOS 路径不应用**（参见 `native_transpile_fixture.json` 的「状态栏美化 / 国内美化」「[美化]变量更新中 / 完整变量完成」两组）。
- **禁止写回 `message.content`**：所有占位符 / 状态栏 / JSON Patch 指令转译**只**通过 `RenderNode` 子树输出；`sample_messages[i].content` 原始字符串必须保持不变，供「复制 / 编辑 / 重新生成」路径使用。

## 包含的文件

- `native_transpile_fixture.json` —— 显示层转译协议夹具：覆盖 7 条 regex_scripts（含两组 iOS 必须跳过的远程脚本）、2 条 sample_messages、init_stat_data 形态、MVU 输出契约（RFC 6902，忽略 `_` 开头 path）。
