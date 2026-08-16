import Foundation

enum WorldBookService {
    static let maxEntries = 20
    static let maxCharacters = 2000

    static func selectedEntries(for input: String, context: String, entries: [WorldBookEntry]) -> [WorldBookEntry] {
        let searchable = (input + "\n" + context).lowercased()

        let matched = entries.filter { entry in
            guard entry.isEnabled else { return false }
            if entry.isConstant { return true }
            return entry.keywords.contains { keyword in
                guard !keyword.isEmpty else { return false }
                let keywordLower = keyword.lowercased()
                switch entry.matchMode {
                case .contains:
                    return searchable.contains(keywordLower)
                case .exact:
                    return matchesExact(keyword: keywordLower, in: searchable)
                }
            }
        }

        let sorted = matched.sorted { $0.priority < $1.priority }

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

    static func injectionText(for entries: [WorldBookEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var parts = ["[世界书]"]
        for entry in entries {
            parts.append("### \(entry.title)")
            parts.append(entry.content)
        }
        return parts.joined(separator: "\n\n")
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
