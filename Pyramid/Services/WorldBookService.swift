import Foundation

enum WorldBookService {
    static let maxEntries = 20
    static let maxCharacters = 2000
    static let defaultScanDepth = 4

    static func selectedEntries(for input: String, history: [ChatMessage], entries: [WorldBookEntry]) -> [WorldBookEntry] {
        var searchableCache: [Int: String] = [:]

        func searchable(for entry: WorldBookEntry) -> String {
            let depth = entry.scanDepth ?? defaultScanDepth
            if let cached = searchableCache[depth] { return cached }
            let context = history.suffix(max(depth, 0)).map(\.content).joined(separator: "\n")
            let text = (input + "\n" + context).lowercased()
            searchableCache[depth] = text
            return text
        }

        let matched = entries.filter { entry in
            guard entry.isEnabled else { return false }
            if entry.isConstant { return true }
            let text = searchable(for: entry)
            let primaryHit = entry.keywords.contains { matches($0, mode: entry.matchMode, in: text) }
            guard primaryHit else { return false }
            if entry.secondaryKeywords.isEmpty { return true }
            return entry.secondaryKeywords.contains { matches($0, mode: entry.matchMode, in: text) }
        }

        // 概率：probability < 100 时按 (条目 id + 匹配文本) 的哈希确定性决定，
        // 同一输入结果稳定；probability=0 永不注入，=100 恒注入。
        let filtered = matched.filter { entry in
            guard entry.probability < 100 else { return true }
            guard entry.probability > 0 else { return false }
            var hasher = Hasher()
            hasher.combine(entry.id)
            hasher.combine(searchable(for: entry))
            return UInt(bitPattern: hasher.finalize()) % 100 < UInt(entry.probability)
        }

        // priority 升序：数值越小越靠前（酒馆 order 也是越小越优先）
        let sorted = filtered.sorted { $0.priority < $1.priority }

        var selected: [WorldBookEntry] = []
        var totalCharacters = 0
        for entry in sorted {
            if selected.count >= maxEntries { break }
            let cost = entry.title.count + entry.content.count
            guard totalCharacters + cost <= maxCharacters else { continue }
            selected.append(entry)
            totalCharacters += cost
        }
        return selected
    }

    static func groupByPosition(_ entries: [WorldBookEntry]) -> [WorldBookInsertionPosition: [WorldBookEntry]] {
        Dictionary(grouping: entries, by: \.insertionPosition)
    }

    static func injectionText(for entries: [WorldBookEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var parts = ["[世界书]"]
        for entry in entries {
            parts.append("### \(entry.title)")
            parts.append(entry.content)
        }
        return parts.joined(separator: "\n\n")
    }

    private static func matches(_ keyword: String, mode: WorldBookMatchMode, in text: String) -> Bool {
        guard !keyword.isEmpty else { return false }
        let keywordLower = keyword.lowercased()
        switch mode {
        case .contains:
            return text.contains(keywordLower)
        case .exact:
            return matchesExact(keyword: keywordLower, in: text)
        }
    }

    private static func matchesExact(keyword: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: keyword, range: searchStart..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let afterOK = range.upperBound == text.endIndex
                || !isWordCharacter(text[range.upperBound])
            if beforeOK && afterOK {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
