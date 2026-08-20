# Fixtures

本目录**当前不含任何 frozen JSON 夹具**。

## 为什么没有 native_transpile_fixture.json

历史版本里这里有一份 `native_transpile_fixture.json`（覆盖 7 条酒馆 regex_scripts + 2 条 sample_messages + init_stat_data 形态 + MVU 输出契约）。该夹具已**主动移除**，原因：

- 夹具字段天然带卡味（角色名 / 卡面路径 / 脚本名），污染通用 1→2 转换设计。
- 本期不实现 1→2 转换函数（下一轮再做）；保留卡味夹具会让"1 与 2 谁负责什么"边界模糊。
- 协议层行为可由**纯抽象用例**完全覆盖，且断言更明确、无需 frozen JSON 解码层。

## 协议层现在的覆盖

转译协议（`<UpdateVariable>` / `<StatusPlaceHolderImpl/>` / HTML beautify 跳过 / `promptOnly` 跳过 / `message.content` 永不被改写 / `_` 前缀 path skip）改由以下不依赖任何角色语义的单元测试覆盖：

- `swift-tests/Tests/PyramidCoreTests/P3TranspileProtocolTests.swift` —— 转译协议 + 跳过规则 + 内容不改写契约（中性路径 `/时间`、`/玩家/当前所在地`）。
- `swift-tests/Tests/PyramidCoreTests/JSONPatchTests.swift` —— RFC 6902 词汇表 + JSON Pointer 解析 + `_` 前缀 skip。

## 硬性边界（保留）

Pyramid 是纯原生 iOS Swift 应用 —— 设计目标彻底摆脱 SillyTavern 浏览器运行环境：

- **禁止 WebView / WKWebView**：测试不依赖 JS 沙箱渲染。
- **禁止执行远程 HTML / JS**：replacement 含 `<script` / `.load(` / `<object>` / `<iframe>` / `<details>` / `<style>` / `<div>` 的 `DisplayRegex` 必须被 `MessageRendererCore.orderedRegexes` 过滤。
- **禁止写回 `message.content`**：所有占位符 / 状态栏 / JSON Patch 指令转译**只**通过 `RenderNode` 子树输出；原文必须保持不变，供「复制 / 编辑 / 重新生成」路径使用。

## 添加新 fixture 时的约束

如果未来需要再放 frozen JSON 进本目录，必须满足：

1. 不引入角色名 / 卡面路径 / 脚本名等卡面语义。
2. 不在协议层职责内（协议层用例请放进 `P3TranspileProtocolTests.swift` 或 `JSONPatchTests.swift`，避免夹具反复 commit 漂移）。
3. 命名清晰说明协议维度（如 `regex_scripts_skip_matrix.json`），不要重蹈 `native_transpile_fixture.json` 这种"什么都能往里塞"的覆辙。