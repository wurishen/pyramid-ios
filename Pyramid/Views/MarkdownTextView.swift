import SwiftUI
import UIKit

// MARK: - 块类型

/// Markdown 块级元素。
/// 每种 case 都对应一种独立的 SwiftUI 渲染（在 `MarkdownTextView.renderBlock` 里），
/// 行内语法（**bold** / *italic* / `code` / [link](url) / ~~strike~~）由
/// `MarkdownTextView.parseInline` 手写 token 解析后挂上显式视觉属性。
enum MarkdownBlock: Hashable {
    case heading(Int, String)                      // level, text  → # / ## / ###
    case paragraph(String)
    case codeBlock(String)
    case blockquote(String)                        // > ...
    case unorderedList([String])
    case orderedList([String])
    case thematicBreak                              // --- / *** / ___
}

// MARK: - 块级解析器

/// 把 Markdown 文本切成块。
/// 设计原则：
/// - 严格按行扫描，遇到下一个块边界立即终止当前块（不跨块合并）。
/// - 列表 / 引用 / 代码块都是「相邻连续行聚合」语义，行间空行会断开。
/// - 不识别的语法降级为段落文本，原样交给行内渲染器处理。
enum MarkdownParser {
    static func blocks(from text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // 空行：跳过，块之间自然断开
            if trimmed.isEmpty {
                index += 1
                continue
            }

            // 标题 # / ## / ###
            if let (level, text) = parseHeading(trimmed) {
                blocks.append(.heading(level, text))
                index += 1
                continue
            }

            // 围栏代码块 ```
            if trimmed.hasPrefix("```") {
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }   // 跳过闭合 ```
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }

            // 分隔线 --- / *** / ___
            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            // 块引用 >
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    if l == ">" {
                        quoteLines.append("")
                        index += 1
                    } else if l.hasPrefix("> ") {
                        quoteLines.append(String(l.dropFirst(2)))
                        index += 1
                    } else if l.isEmpty {
                        // 空行结束引用块
                        break
                    } else {
                        break
                    }
                }
                let joinedQuotes = quoteLines.reduce(into: "") { acc, line in
                    if !acc.isEmpty { acc += "\n" }
                    acc += line
                }
                blocks.append(.blockquote(joinedQuotes))
                continue
            }

            // 无序列表 - / * / +
            if unorderedPrefix(trimmed) != nil {
                var items: [String] = []
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    if let p = unorderedPrefix(l) {
                        items.append(String(l.dropFirst(p.count)))
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // 有序列表 1. / 2. / ...
            if let content = orderedItemContent(trimmed) {
                var items: [String] = [content]
                index += 1
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    if let c = orderedItemContent(l) {
                        items.append(c)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.orderedList(items))
                continue
            }

            // 段落：连续非空、非块边界的行合并
            var paragraphLines: [String] = [raw]
            index += 1
            while index < lines.count {
                let nextRaw = lines[index]
                let next = nextRaw.trimmingCharacters(in: .whitespaces)
                if next.isEmpty { break }
                if parseHeading(next) != nil { break }
                if next.hasPrefix("```") { break }
                if isThematicBreak(next) { break }
                if next == ">" || next.hasPrefix("> ") { break }
                if unorderedPrefix(next) != nil { break }
                if orderedItemContent(next) != nil { break }
                paragraphLines.append(nextRaw)
                index += 1
            }
            let joinedParagraph = paragraphLines.reduce(into: "") { acc, line in
                if !acc.isEmpty { acc += "\n" }
                acc += line
            }
            blocks.append(.paragraph(joinedParagraph))
        }

        return blocks
    }

    // 标题：1-6 个 `#`，后接空格，再接文本
    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: "^(#{1,6})\\s+(.+)$") else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let hashRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line)
        else { return nil }
        return (line[hashRange].count, String(line[textRange]))
    }

    // 分隔线：--- / *** / ___（≥3 个相同字符，仅允许空白）
    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard let first = stripped.first, first == "-" || first == "*" || first == "_" else { return false }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    // 无序列表前缀（带尾随空格）
    private static func unorderedPrefix(_ line: String) -> String? {
        if line == "-" || line == "*" || line == "+" { return nil }
        if line.hasPrefix("- ") { return "- " }
        if line.hasPrefix("* ") { return "* " }
        if line.hasPrefix("+ ") { return "+ " }
        return nil
    }

    // 有序列表项：`数字 + . + 空格 + 内容`
    private static func orderedItemContent(_ line: String) -> String? {
        guard let dotIdx = line.firstIndex(of: ".") else { return nil }
        let numPart = line[line.startIndex..<dotIdx]
        guard !numPart.isEmpty, numPart.allSatisfy({ $0.isNumber }) else { return nil }
        let afterDot = line.index(after: dotIdx)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let contentStart = line.index(after: afterDot)
        return String(line[contentStart...])
    }
}

// MARK: - 渲染视图

/// 把 Markdown 文本渲染成 SwiftUI 富文本。
/// 流水线：原始文本 → `MarkdownParser.blocks` 切成块 → 每块独立 SwiftUI View →
/// 行内语法（**bold** / *italic* / `code` / ~~strike~~ / [text](url)）由
/// `parseInline` 手写 token 解析后挂上显式 `.font` / `.foregroundColor` /
/// `.backgroundColor` / `.underlineStyle` / `.strikethroughStyle` / `.link` 属性。
///
/// 关键点：**不再** 走 `AttributedString(markdown:)`。iOS 17 上把整段 markdown
/// 丢给 AttributedString(markdown:) 时，行内语法（** / * / `）会被剥离但视觉属性
/// 不一定真正生效——`Text(AttributedString)` 偶尔只会显示成普通字符串。手写 token
/// 解析 + 显式属性可以保证每个 Markdown 语义都对应到 SwiftUI 的视觉样式。
///
/// 与 `MessageRenderer.preprocess(_:)` 配合：`preprocess` 先做 DisplayRegex + 隐藏标签剥离，
/// 清洗后的 String 再交给本视图渲染（不动 `message.content`）。
struct MarkdownTextView: View {
    let text: String
    /// 客户端界面整体缩放系数（来自 AppSettings.uiScale.factor）。
    /// 默认为 1.0；上游（MessageCard）按 `settings.uiScale.factor` 传入。
    /// 作用于：内层 VStack 间距、块级 padding、标题/正文/行内字体。
    var uiScale: CGFloat = 1.0

    private var blocks: [MarkdownBlock] {
        MarkdownParser.blocks(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            UIApplication.shared.open(url)
            return .handled
        })
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(parseInline(text))
                .font(headingFont(level: level))
                .fontWeight(level <= 2 ? .bold : .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, (level <= 2 ? 4 : 2) * uiScale)
        case .paragraph(let text):
            Text(parseInline(text))
                .font(.system(size: 17 * uiScale))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 17 * uiScale, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 2 * uiScale)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10 * uiScale)
            .background(Color(.systemGray6))
            .overlay(
                RoundedRectangle(cornerRadius: 8 * uiScale)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8 * uiScale))
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3 * uiScale)
                Text(parseInline(text))
                    .font(.system(size: 17 * uiScale))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10 * uiScale)
                    .padding(.vertical, 2 * uiScale)
            }
            .padding(.vertical, 2 * uiScale)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8 * uiScale) {
                        Text("•")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 17 * uiScale))
                        Text(parseInline(item))
                            .font(.system(size: 17 * uiScale))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 4 * uiScale)
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8 * uiScale) {
                        Text("\(idx + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .font(.system(size: 17 * uiScale))
                        Text(parseInline(item))
                            .font(.system(size: 17 * uiScale))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 4 * uiScale)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 6 * uiScale)
        }
    }

    private func headingFont(level: Int) -> Font {
        // 显式按 uiScale 缩放；改用 .system(size:) 而非 .title 等语义样式，
        // 因为后者走 Dynamic Type，而我们这里要叠加客户端 uiScale。
        let size: CGFloat
        switch level {
        case 1: size = 28
        case 2: size = 22
        case 3: size = 20
        case 4: size = 17
        case 5: size = 15
        default: size = 17
        }
        return .system(size: size * uiScale, weight: .semibold)
    }

    /// 行内语法 token 解析器。把 `**bold**` / `*italic*` / `` `code` `` / `~~strike~~`
    /// / `[text](url)` 切成片段，并为每个匹配片段挂上 SwiftUI 视觉属性。
    ///
    /// 优先级（长前缀优先）：` ** ` → ` ~~ ` → ` ` ` → ` * ` → ` [text](url) ` → 普通字符。
    /// 之所以手动实现而不是用 `AttributedString(markdown:)`，是因为后者在 iOS 17
    /// 的 inlineOnly 模式下常出现「符号被剥掉但视觉属性没真正生效」的回归。
    ///
    /// 输出：`Text(AttributedString)` 会按 attribute 直接渲染：
    /// - **bold**：`.font = .body.weight(.bold)` + `.inlinePresentationIntent = .stronglyEmphasized`
    /// - *italic*：`.font = .body.italic()` + `.inlinePresentationIntent = .emphasized`
    /// - `code`：`.font = .system(.body, design: .monospaced)` + `.backgroundColor` + `.inlinePresentationIntent = .code`
    /// - ~~strike~~：`.strikethroughStyle = .single` + `.inlinePresentationIntent = .strikethrough`
    /// - [text](url)：`.link = URL` + `.foregroundColor = .accentColor` + `.underlineStyle = .single`
    private func parseInline(_ string: String) -> AttributedString {
        var result = AttributedString()
        var idx = string.startIndex
        // 行内语法 token 解析后挂上显式 `.font`（已按 uiScale 缩放）。
        let bodySize: CGFloat = 17 * uiScale

        while idx < string.endIndex {
            let remaining = Substring(string[idx...])
            let startOffset = remaining.startIndex

            // 1) **bold** —— 最长前缀优先，避免被单 * 误吃
            if remaining.hasPrefix("**") {
                let afterOpen = remaining.index(startOffset, offsetBy: 2)
                if let closeRange = remaining.range(of: "**", options: .literal, range: afterOpen..<remaining.endIndex),
                   closeRange.lowerBound > afterOpen {
                    let content = String(remaining[afterOpen..<closeRange.lowerBound])
                    var seg = AttributedString(content)
                    seg.font = .system(size: bodySize, weight: .bold)
                    seg.inlinePresentationIntent = .stronglyEmphasized
                    result.append(seg)
                    idx = advance(idx: idx, by: remaining.distance(from: startOffset, to: closeRange.upperBound), in: string)
                    continue
                }
            }

            // 2) ~~strikethrough~~
            if remaining.hasPrefix("~~") {
                let afterOpen = remaining.index(startOffset, offsetBy: 2)
                if let closeRange = remaining.range(of: "~~", options: .literal, range: afterOpen..<remaining.endIndex),
                   closeRange.lowerBound > afterOpen {
                    let content = String(remaining[afterOpen..<closeRange.lowerBound])
                    var seg = AttributedString(content)
                    seg.strikethroughStyle = .single
                    seg.inlinePresentationIntent = .strikethrough
                    result.append(seg)
                    idx = advance(idx: idx, by: remaining.distance(from: startOffset, to: closeRange.upperBound), in: string)
                    continue
                }
            }

            // 3) `inline code` —— 等宽字体 + 浅背景
            if remaining.first == "`" {
                let afterOpen = remaining.index(after: startOffset)
                if let closeRange = remaining.range(of: "`", options: .literal, range: afterOpen..<remaining.endIndex),
                   closeRange.lowerBound > afterOpen {
                    let content = String(remaining[afterOpen..<closeRange.lowerBound])
                    var seg = AttributedString(content)
                    seg.font = .system(size: bodySize, design: .monospaced)
                    seg.backgroundColor = Color.secondary.opacity(0.18)
                    seg.inlinePresentationIntent = .code
                    result.append(seg)
                    idx = advance(idx: idx, by: remaining.distance(from: startOffset, to: closeRange.upperBound), in: string)
                    continue
                }
            }

            // 4) *italic* —— 单星；** 已被吃掉，扫到下一个不与邻居配对的 *
            if remaining.first == "*" {
                let afterOpen = remaining.index(after: startOffset)
                var scan = afterOpen
                var foundClose: String.Index? = nil
                while scan < remaining.endIndex {
                    if remaining[scan] == "*" {
                        let prev = remaining.index(before: scan)
                        let next = remaining.index(after: scan)
                        let prevIsStar = prev >= afterOpen && remaining[prev] == "*"
                        let nextIsStar = next < remaining.endIndex && remaining[next] == "*"
                        if !prevIsStar && !nextIsStar && scan > afterOpen {
                            foundClose = scan
                            break
                        }
                    }
                    scan = remaining.index(after: scan)
                }
                if let close = foundClose {
                    let content = String(remaining[afterOpen..<close])
                    var seg = AttributedString(content)
                    seg.font = .system(size: bodySize).italic()
                    seg.inlinePresentationIntent = .emphasized
                    result.append(seg)
                    idx = advance(idx: idx, by: remaining.distance(from: startOffset, to: remaining.index(after: close)), in: string)
                    continue
                }
            }

            // 5) [text](url) —— 链接
            if remaining.first == "[" {
                if let linkEnd = remaining.range(of: "](", options: .literal, range: startOffset..<remaining.endIndex),
                   let urlEnd = remaining.range(of: ")", options: .literal, range: linkEnd.upperBound..<remaining.endIndex) {
                    let content = String(remaining[remaining.index(after: startOffset)..<linkEnd.lowerBound])
                    let url = String(remaining[linkEnd.upperBound..<urlEnd.lowerBound])
                    if !content.isEmpty,
                       !content.contains("\n"),
                       !url.contains("\n"),
                       !url.contains(" "),
                       let parsed = URL(string: url) {
                        var seg = AttributedString(content)
                        // link attribute 在 Foundation scope（SwiftUI scope 没有）。
                        // 没有 import UIKit 所以不会与 UIKit scope 歧义。
                        seg[AttributeScopes.FoundationAttributes.LinkAttribute.self] = parsed
                        seg.foregroundColor = .accentColor
                        seg.underlineStyle = .single
                        result.append(seg)
                        idx = advance(idx: idx, by: remaining.distance(from: startOffset, to: urlEnd.upperBound), in: string)
                        continue
                    }
                }
            }

            // 无匹配：拷贝 1 个字符
            let ch = remaining.first!
            result.append(AttributedString(String(ch)))
            idx = string.index(after: idx)
        }

        return result
    }

    /// `String.index(_:offsetBy:)` 的小封装，避免每个分支重复写。
    private func advance(idx: String.Index, by offset: Int, in string: String) -> String.Index {
        string.index(idx, offsetBy: offset)
    }
}

// MARK: - SwiftUI Preview

#Preview("MarkdownTextView - all block types") {
    let sample = """
    # Heading 1
    ## Heading 2
    ### Heading 3

    Paragraph with **bold**, *italic*, `inline code`, ~~strike~~, [link](https://example.com).

    > Blockquote line one
    > Blockquote line two

    - unordered item A
    - unordered item B

    1. ordered item one
    2. ordered item two

    ```swift
    let code = "fenced"
    print(code)
    ```

    ---

    Plain paragraph after divider.
    """
    return ScrollView {
        MarkdownTextView(text: sample)
            .padding()
    }
}

#Preview("MarkdownTextView - inline only") {
    ScrollView {
        MarkdownTextView(text: "**bold** *italic* `code` ~~strike~~ [link](https://example.com)")
            .padding()
    }
}

#Preview("MarkdownTextView - empty") {
    MarkdownTextView(text: "")
        .padding()
}