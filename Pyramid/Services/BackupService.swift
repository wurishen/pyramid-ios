import Foundation

/// 全量备份的结构：会话 / 角色 / 世界书 / 预设 / 用户人设 / 当前会话指针。
/// 单 JSON 文件，方便真机通过「文件」App 读取或迁移。
struct PyramidBackup: Codable {
    var version: Int
    var exportedAt: Date
    var sessions: [ChatSession]
    var currentSessionID: UUID?
    var characters: [Character]
    var worldBooks: [WorldBook]
    var presets: [Preset]
    var userName: String
    var userDisplayName: String
    var userAvatarData: Data
    var userPersona: String
    var userPersonaInjected: Bool

    init(version: Int = 1,
         exportedAt: Date = Date(),
         sessions: [ChatSession],
         currentSessionID: UUID?,
         characters: [Character],
         worldBooks: [WorldBook],
         presets: [Preset],
         userName: String = "",
         userDisplayName: String = "",
         userAvatarData: Data = Data(),
         userPersona: String = "",
         userPersonaInjected: Bool = true) {
        self.version = version
        self.exportedAt = exportedAt
        self.sessions = sessions
        self.currentSessionID = currentSessionID
        self.characters = characters
        self.worldBooks = worldBooks
        self.presets = presets
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.userAvatarData = userAvatarData
        self.userPersona = userPersona
        self.userPersonaInjected = userPersonaInjected
    }
}

enum BackupError: LocalizedError {
    case invalidData
    case versionMismatch(Int)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "备份文件无法解析：不是 Pyramid 备份格式。"
        case .versionMismatch(let v):
            return "备份版本不兼容：服务器给出 \(v)，本机仅支持 1。"
        }
    }
}

enum BackupService {
    static func parseBackup(from url: URL) throws -> PyramidBackup {
        let data = try ImportSupport.readImportedData(from: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: PyramidBackup
        do {
            backup = try decoder.decode(PyramidBackup.self, from: data)
        } catch {
            throw BackupError.invalidData
        }
        guard backup.version == 1 else { throw BackupError.versionMismatch(backup.version) }
        return backup
    }

    #if canImport(SwiftUI)
    static func makeBackup(
        store: ChatStore,
        characters: CharacterStore,
        worldBook: WorldBookStore,
        presets: PresetStore,
        settings: AppSettings
    ) throws -> URL {
        let backup = PyramidBackup(
            sessions: store.sessions,
            currentSessionID: store.currentSessionID,
            characters: characters.characters,
            worldBooks: worldBook.books,
            presets: presets.presets,
            userName: settings.userName,
            userDisplayName: settings.userDisplayName,
            userAvatarData: settings.userAvatarData,
            userPersona: settings.userPersona,
            userPersonaInjected: settings.userPersonaInjected
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        let filename = "pyramid-backup-\(Self.timestampString()).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 合并：按 id 去重，已有则保留本机版本，新条目追加。
    /// 覆盖：清空本机所有数据后替换。
    /// 会话、角色、世界书、预设都按 id 维度合并。
    static func merge(backup: PyramidBackup,
                      store: ChatStore,
                      characters: CharacterStore,
                      worldBook: WorldBookStore,
                      presets: PresetStore,
                      settings: AppSettings) {
        mergeByID(into: &store.sessions, items: backup.sessions)
        mergeByID(into: &characters.characters, items: backup.characters)
        mergeByID(into: &worldBook.books, items: backup.worldBooks)
        mergeByID(into: &presets.presets, items: backup.presets)
        if let id = backup.currentSessionID,
           store.sessions.contains(where: { $0.id == id }) {
            store.currentSessionID = id
        }
        applyUserPersona(backup: backup, settings: settings)
        store.save()
        characters.save()
        worldBook.save()
        presets.save()
    }

    static func overwrite(backup: PyramidBackup,
                          store: ChatStore,
                          characters: CharacterStore,
                          worldBook: WorldBookStore,
                          presets: PresetStore,
                          settings: AppSettings) {
        store.sessions = backup.sessions
        store.currentSessionID = backup.sessions.first?.id
        characters.characters = backup.characters
        worldBook.books = backup.worldBooks
        presets.presets = backup.presets
        applyUserPersona(backup: backup, settings: settings)
        store.save()
        characters.save()
        worldBook.save()
        presets.save()
    }

    private static func applyUserPersona(backup: PyramidBackup, settings: AppSettings) {
        settings.userName = backup.userName
        settings.userDisplayName = backup.userDisplayName
        settings.userAvatarData = backup.userAvatarData
        settings.userPersona = backup.userPersona
        settings.userPersonaInjected = backup.userPersonaInjected
    }

    private static func mergeByID<T: Identifiable>(into target: inout [T], items: [T]) {
        let existing = Set(target.map { $0.id })
        for item in items where !existing.contains(item.id) {
            target.append(item)
        }
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
    #endif
}
