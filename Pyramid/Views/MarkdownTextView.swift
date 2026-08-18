import SwiftUI
import UIKit

// MARK: - 块类型

/// Markdown 块级元素。
/// 每种 case 都对应一种独立的 SwiftUI 渲染（在 `MarkdownTextView.renderBlock` 里），
/// 行内语法（**bold** / *italic* / `code` / [link](url) / ~~strike~~）由
/// `AttributedString(markdown:)` 在每个块内部处理。
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
/// 行内语法（**bold** / *italic* / `~~strike~~` / `` `code` `` / `[link](url)`）
/// 由 `AttributedString(markdown:options:)` 解析后塞进对应 View。
///
/// 与 `MessageRenderer.preprocess(_:)` 配合：`preprocess` 先做 DisplayRegex + 隐藏标签剥离，
/// 清洗后的 String 再交给本视图渲染（不动 `message.content`）。
struct MarkdownTextView: View {
    let text: String

    private var blocks: [MarkdownBlock] {
        MarkdownParser.blocks(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(parseInline(text))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(parseInline(text))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(parseInline(item))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(parseInline(item))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        case .thematicBreak:
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        case 5: return .subheadline
        default: return .body
        }
    }

    /// 行内语法解析：交给 SwiftUI 原生 AttributedString(markdown:)。
    /// `interpretedSyntax = .inlineOnlyPreservingWhitespace` 只解析行内（bold/italic/code/link/strike），
    /// 块级标记（# / - 等）已经被 `MarkdownParser` 处理过，不应该再被这里二次解析。
    /// `failurePolicy = .returnPartiallyParsedIfPossible` 让部分失败保留已解析范围。
    private func parseInline(_ string: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.allowsExtendedAttributes = true
        options.failurePolicy = .returnPartiallyParsedIfPossible
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}