import XCTest
@testable import PyramidCore

final class ContextTrimModeTests: XCTestCase {

    func test_allCases() {
        XCTAssertEqual(ContextTrimMode.allCases.count, 3)
        XCTAssertTrue(ContextTrimMode.allCases.contains(.off))
        XCTAssertTrue(ContextTrimMode.allCases.contains(.byMessages))
        XCTAssertTrue(ContextTrimMode.allCases.contains(.byCharacters))
    }

    func test_rawValueRoundTrip() {
        for mode in ContextTrimMode.allCases {
            XCTAssertEqual(ContextTrimMode(rawValue: mode.rawValue), mode)
        }
    }

    func test_identifiableIDEqualsRawValue() {
        for mode in ContextTrimMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func test_invalidRawValueReturnsNil() {
        XCTAssertNil(ContextTrimMode(rawValue: "nonsense"))
    }

    func test_labels() {
        XCTAssertEqual(ContextTrimMode.off.label, "不裁剪")
        XCTAssertEqual(ContextTrimMode.byMessages.label, "最近 N 条消息")
        XCTAssertEqual(ContextTrimMode.byCharacters.label, "最近 C 字符")
    }
}
