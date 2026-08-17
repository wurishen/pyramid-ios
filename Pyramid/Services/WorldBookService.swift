import Foundation
import os

enum WorldBookService {
    static let maxEntries = 20
    static let maxCharacters = 2000
    static let defaultScanDepth = 4

    // MARK: - Item 6 H5：每条目的「懒编译」小写关键字缓存
    //
    // 旧实现每次 selectedEntries 都 entry.keywords.map { $0.lowercased() } +
    // matches(...) 内部再 keyword.lowercased()：N 本书 × M 条目 × K 关键字的输入下，
    // 每轮请求都要重复小写化字符串。WorldBookEntry 由 value 持有但 ID 稳定，
    // 这里按 id 缓存 (primaryLower, secondaryLower) + hash 校验关键字是否改了，
    // 改后自动重建。匹配语义不变 —— matches 仍接收已小写化字符串。
    private struct KeywordSnapshot {
        let primaryHash: Int
        let secondaryHash: Int
        let primary: [String]
        let secondary: [String]
    }
    private static let lowercasedKeywordsCache = OSAllocatedUnfairLock<[UUID: KeywordSnapshot]>(initialState: [:])

    /// 读取 / 构建某条目的小写化关键字。命中缓存且关键字未变则复用；否则重建。
    static func lowercasedKeywords(for entry: WorldBookEntry) -> (primary: [String], secondary: [String]) {
        let primaryHash = entry.keywords.reduce(0) { $0 ^ $1.hashValue }
        let secondaryHash = entry.secondaryKeywords.reduce(0) { $0 ^ $1.hashValue }
        return lowercasedKeywordsCache.withLock { cache in
            if let snap = cache[entry.id],
               snap.primaryHash == primaryHash,
               snap.secondaryHash == secondaryHash {
                return (snap.primary, snap.secondary)
            }
            let p = entry.keywords.map { $0.lowercased() }
            let s = entry.secondaryKeywords.map { $0.lowercased() }
            cache[entry.id] = KeywordSnapshot(
                primaryHash: primaryHash,
                secondaryHash: secondaryHash,
                primary: p,
                secondary: s
            )
            return (p, s)
        }
    }

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
            // Item 6 H5：使用每条目懒编译的小写关键字，避免每次调用再 lowercase
            let lowered = lowercasedKeywords(for: entry)
            let primaryHit = lowered.primary.contains { matches($0, mode: entry.matchMode, in: text) }
            guard primaryHit else { return false }
            if lowered.secondary.isEmpty { return true }
            return lowered.secondary.contains { matches($0, mode: entry.matchMode, in: text) }
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

    private static func matches(_ keywordLower: String, mode: WorldBookMatchMode, in text: String) -> Bool {
        // Item 6 H5：调用方已通过 `lowercasedKeywords(for:)` 提供小写形式，
        // 这里不再重复 lowercase。text 也在 `searchable(for:)` 里已统一小写化。
        guard !keywordLower.isEmpty else { return false }
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

    private static func isWordCharacter(_ char: Swift.Character) -> Bool {
        char.isLetter || char.isNumber || char == "_"
    }
}
