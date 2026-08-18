import SwiftUI
import UIKit

enum MarkdownBlock: Hashable {
    case paragraph(String)
    case codeBlock(String)
    case list([MarkdownListItem])
}

struct MarkdownListItem: Hashable {
    let prefix: String
    let content: String
}

enum MarkdownParser {
    static func blocks(from text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }

            if let item = listItem(from: line) {
                var items = [item]
                index += 1
                while index < lines.count, let next = listItem(from: lines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if next.hasPrefix("```") { break }
                if listItem(from: next) != nil { break }
                paragraphLines.append(next)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }

    private static func listItem(from line: String) -> MarkdownListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return MarkdownListItem(
                prefix: "•",
                content: String(trimmed.dropFirst(2))
            )
        }

        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let numberPart = trimmed[trimmed.startIndex..<dotIndex]
        guard !numberPart.isEmpty, numberPart.allSatisfy({ $0.isNumber }) else { return nil }
        let afterDotIndex = trimmed.index(after: dotIndex)
        let afterDot = trimmed[afterDotIndex...]
        guard afterDot.first == " " else { return nil }
        return MarkdownListItem(
            prefix: String(trimmed[trimmed.startIndex...dotIndex]) + " ",
            content: String(afterDot)
        )
    }
}

struct MarkdownTextView: View {
    let text: String

    var body: some View {
        // 直接把整段文本交给 SwiftUI 原生 AttributedString(markdown:) 解析：
        //   **bold** / *italic* / ~~strike~~ / `code` / [link](url) / 围栏代码块 都会被渲染。
        // 之前用一个手写的块级 parser 把文本切成 paragraph / code / list 再分别渲染，
        // 在某些文本（例如单行内联 markdown）上会"看着像没渲染"——根因是逐块解析
        // 加上 AttributedString 失败时静默回退到纯文本，肉眼难分辨。
        // 这里改成「一次解析整段」，并用 .returnPartiallyParsedIfPossible 让部分
        // 失败也尽量保留已解析的范围；最终失败再回退到纯文本（不抛错）。
        Text(attributed(text))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                UIApplication.shared.open(url)
                return .handled
            })
    }

    private func attributed(_ string: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.allowsExtendedAttributes = true
        options.failurePolicy = .returnPartiallyParsedIfPossible
        options.interpretedSyntax = .full
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}
