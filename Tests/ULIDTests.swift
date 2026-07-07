import XCTest
@testable import Dump

final class ULIDTests: XCTestCase {
    func testHas26CharsAndCrockfordAlphabet() {
        let id = ULID().value
        XCTAssertEqual(id.count, 26)
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for scalar in id.unicodeScalars {
            XCTAssertTrue(allowed.contains(scalar), "unexpected char \(scalar)")
        }
    }

    func testLexicographicOrderingByTimestamp() {
        let earlier = ULID(timestamp: Date(timeIntervalSince1970: 1_000_000), randomness: Array(repeating: 0, count: 10))
        let later = ULID(timestamp: Date(timeIntervalSince1970: 1_000_001), randomness: Array(repeating: 0, count: 10))
        XCTAssertLessThan(earlier.value, later.value)
    }

    func testDeterministicWithFixedSeed() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = ULID(timestamp: date, randomness: Array(repeating: 0xAB, count: 10))
        let b = ULID(timestamp: date, randomness: Array(repeating: 0xAB, count: 10))
        XCTAssertEqual(a.value, b.value)
    }
}
