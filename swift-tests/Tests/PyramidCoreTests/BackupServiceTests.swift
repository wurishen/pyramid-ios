import XCTest
@testable import PyramidCore

final class BackupServiceTests: XCTestCase {

    // MARK: - PyramidBackup

    func test_backupCodableRoundTrip() throws {
        let original = PyramidBackup(
            version: 1,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessions: [],
            currentSessionID: nil,
            characters: [],
            worldBooks: [],
            presets: [],
            userName: "Alice",
            userDisplayName: "ali",
            userAvatarData: Data([0x01, 0x02, 0x03]),
            userPersona: "kind",
            userPersonaInjected: true
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(original)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(PyramidBackup.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.userName, "Alice")
        XCTAssertEqual(decoded.userDisplayName, "ali")
        XCTAssertEqual(decoded.userAvatarData, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(decoded.userPersona, "kind")
        XCTAssertEqual(decoded.userPersonaInjected, true)
    }

    // MARK: - BackupError

    func test_invalidDataErrorDescription() {
        let err = BackupError.invalidData
        XCTAssertNotNil(err.errorDescription)
        XCTAssertTrue(err.errorDescription!.contains("Pyramid"))
    }

    func test_versionMismatchErrorDescription() {
        let err = BackupError.versionMismatch(7)
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("7"))
        XCTAssertTrue(desc.contains("1"))
    }

    // MARK: - parseBackup

    private func writeTempBackup(_ backup: PyramidBackup) throws -> URL {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(backup)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pyramid-test-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func test_parseBackupHappyPath() throws {
        let backup = PyramidBackup(
            sessions: [],
            currentSessionID: nil,
            characters: [],
            worldBooks: [],
            presets: []
        )
        let url = try writeTempBackup(backup)
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try BackupService.parseBackup(from: url)
        XCTAssertEqual(parsed.version, 1)
    }

    func test_parseBackupVersionMismatch() throws {
        let json = """
        {"version": 99, "exportedAt": "2026-08-21T00:00:00Z",
         "sessions": [], "currentSessionID": null,
         "characters": [], "worldBooks": [], "presets": [],
         "userName": "", "userDisplayName": "", "userAvatarData": "",
         "userPersona": "", "userPersonaInjected": true}
        """.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pyramid-test-\(UUID().uuidString).json")
        try json.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try BackupService.parseBackup(from: url)) { err in
            guard case BackupError.versionMismatch(let v) = err else {
                return XCTFail("expected versionMismatch, got \(err)")
            }
            XCTAssertEqual(v, 99)
        }
    }

    func test_parseBackupInvalidData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pyramid-test-\(UUID().uuidString).json")
        try "not json at all".data(using: .utf8)!.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try BackupService.parseBackup(from: url)) { err in
            guard case BackupError.invalidData = err else {
                return XCTFail("expected invalidData, got \(err)")
            }
        }
    }

    func test_parseBackupMalformedJSONObject() throws {
        // 合法 JSON 但不是 PyramidBackup schema
        let json = #"{"foo": "bar"}"#.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pyramid-test-\(UUID().uuidString).json")
        try json.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try BackupService.parseBackup(from: url))
    }
}
