import Foundation
import os

enum WorldBookService {
    static let maxEntries = 20
    static let maxCharacters = 2000
    static let defaultScanDepth = 4

    // MARK: - Item 6 H5：每条目的「懒编译」小写关键字缓存（保留作旧 API）
    private struct KeywordSnapshot {
        let primaryHash: Int
        let secondaryHash: Int
        let primary: [String]
        let secondary: [String]
    }
    private static let lowercasedKeywordsCache = OSAllocatedUnfairLock<[UUID: KeywordSnapshot]>(initialState: [:])

    /// 读取 / 构建某条目的小写化关键字。命中缓存且关键字未变则复用；否则重建。
    /// 注意：**不感知 caseSensitive** —— 调用方若需大小写敏感应自行处理。
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
        // 阶段 1：基础过滤（enabled + weight <= 0 视为关闭）
        let enabled = entries.filter { entry in
            guard entry.isEnabled else { return false }
            if let w = entry.weight, w <= 0 { return false }
            return true
        }

        // 阶段 2：keyword 匹配（caseSensitive / triggers / excludes / selectiveLogic）
        var searchableCache: [String: String] = [:]
        let matched = enabled.filter { entry in
            if entry.isConstant { return true }
            let text = searchableText(for: entry, input: input, history: history, cache: &searchableCache)
            return matchesKeywords(entry, rawText: text)
        }

        // 阶段 3：概率门控
        let afterProb = matched.filter { entry in
            guard entry.probability < 100 else { return true }
            guard entry.probability > 0 else { return false }
            let text = searchableText(for: entry, input: input, history: history, cache: &searchableCache)
            var hasher = Hasher()
            hasher.combine(entry.id)
            hasher.combine(text)
            return UInt(bitPattern: hasher.finalize()) % 100 < UInt(entry.probability)
        }

        // 阶段 4：V3 group scoring —— useGroupScoring=true 的同 groupKey 条目只留优先级最高的一条
        let afterGroups = applyGroupScoring(afterProb)

        // 阶段 5：effective sort key（priority + decay 推后 + weight 提前 tiebreaker）
        let sorted = afterGroups.sorted { effectiveSortKey($0) < effectiveSortKey($1) }

        // 阶段 6：maxEntries + maxCharacters 截断
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

    // MARK: - V3 字段运行时支持

    /// 构造条目搜索文本：按 (depth, caseSensitive) 缓存。
    /// caseSensitive=true → 保留原文大小写；否则统一小写。
    private static func searchableText(
        for entry: WorldBookEntry,
        input: String,
        history: [ChatMessage],
        cache: inout [String: String]
    ) -> String {
        let depth = entry.scanDepth ?? defaultScanDepth
        let cs = entry.caseSensitive == true
        let key = "\(depth)-\(cs ? "cs" : "ci")"
        if let cached = cache[key] { return cached }
        let context = history.suffix(max(depth, 0)).map(\.content).joined(separator: "\n")
        let raw = input + "\n" + context
        cache[key] = cs ? raw : raw.lowercased()
        return cache[key]!
    }

    /// V3 keyword 匹配：primary（必备）+ secondary（按 selectiveLogic）+ triggers（至少一个）+ excludes（不得出现）。
    /// selectiveLogic（仅作用于 secondary）：
    /// - 0 / nil（AND_ANY）：至少一个 secondary 命中
    /// - 1（NOT_ALL）：全部 secondary 命中 → 排除
    /// - 2（NOT_ANY）：任一 secondary 命中 → 排除
    /// - 3（AND_ALL）：全部 secondary 命中
    private static func matchesKeywords(_ entry: WorldBookEntry, rawText: String) -> Bool {
        let cs = entry.caseSensitive == true
        let primary = cs ? entry.keywords : entry.keywords.map { $0.lowercased() }
        let secondary = cs ? entry.secondaryKeywords : entry.secondaryKeywords.map { $0.lowercased() }
        let triggers = cs ? entry.triggers : entry.triggers.map { $0.lowercased() }
        let excludes = cs ? entry.excludes : entry.excludes.map { $0.lowercased() }

        // primary：至少一个必须命中（空 primary 视为无需 keyword 触发）
        if !primary.isEmpty {
            let hit = primary.contains { matches($0, mode: entry.matchMode, in: rawText) }
            guard hit else { return false }
        }

        // secondary：按 selectiveLogic 决定匹配 / 排除
        if !secondary.isEmpty {
            let logic = entry.selectiveLogicRaw ?? 0
            let anyHit = secondary.contains { matches($0, mode: entry.matchMode, in: rawText) }
            let allHit = secondary.allSatisfy { matches($0, mode: entry.matchMode, in: rawText) }
            switch logic {
            case 1:  // NOT_ALL
                if allHit { return false }
            case 2:  // NOT_ANY
                if anyHit { return false }
            case 3:  // AND_ALL
                if !allHit { return false }
            default: // 0 / nil → AND_ANY
                if !anyHit { return false }
            }
        }

        // triggers：至少一个命中
        if !triggers.isEmpty {
            let hit = triggers.contains { matches($0, mode: entry.matchMode, in: rawText) }
            guard hit else { return false }
        }

        // excludes：任一命中 → 排除
        if !excludes.isEmpty {
            let hit = excludes.contains { matches($0, mode: entry.matchMode, in: rawText) }
            if hit { return false }
        }

        return true
    }

    /// V3 group scoring：useGroupScoring=true 且 groupKey 非空的同组条目仅保留优先级最高的一条。
    /// 组内并列时 groupWeight 高者优先（仍 nil 时按 0 比）。
    private static func applyGroupScoring(_ entries: [WorldBookEntry]) -> [WorldBookEntry] {
        var groupsToFilter: [String: [WorldBookEntry]] = [:]
        var ungrouped: [WorldBookEntry] = []
        for entry in entries {
            if entry.useGroupScoring == true, let g = entry.groupKey, !g.isEmpty {
                groupsToFilter[g, default: []].append(entry)
            } else {
                ungrouped.append(entry)
            }
        }

        var selected = ungrouped
        for (_, groupEntries) in groupsToFilter {
            let top = groupEntries.min { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return (lhs.groupWeight ?? 0) > (rhs.groupWeight ?? 0)
            }
            if let t = top { selected.append(t) }
        }
        return selected
    }

    /// V3 effective sort key = priority + decay 推后偏移 + weight tiebreaker。
    /// - decay ∈ [0,1]：decay 越小优先级数字越大（推后）；decay=1 不变；decay=0 加 1000。
    /// - weight > 0：作 tiebreaker（weight 大 → 排得更前）。
    private static func effectiveSortKey(_ entry: WorldBookEntry) -> Double {
        let priority = Double(entry.priority)
        let decayBoost: Double
        if let d = entry.decay, d >= 0, d <= 1 {
            decayBoost = (1.0 - d) * 1000.0
        } else {
            decayBoost = 0
        }
        let weightTiebreaker: Double
        if let w = entry.weight, w > 0 {
            weightTiebreaker = -w * 0.001
        } else {
            weightTiebreaker = 0
        }
        return priority + decayBoost + weightTiebreaker
    }

    // MARK: - 原有 API（不变）

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
