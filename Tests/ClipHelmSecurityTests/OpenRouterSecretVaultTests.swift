import Foundation
import XCTest
@testable import ClipHelmSecurity

final class OpenRouterSecretVaultTests: XCTestCase {
    func testKeychainSaveReplaceAndRemove() throws {
        let service = "com.cliphelm.tests.\(UUID().uuidString)"
        let vault = OpenRouterSecretVault(service: service)
        defer { try? vault.remove() }
        XCTAssertFalse(try vault.hasKey())

        let first = "test-\(UUID().uuidString)"
        let second = "test-\(UUID().uuidString)"
        try vault.save(first)
        XCTAssertTrue(try vault.hasKey())
        XCTAssertEqual(try vault.readKey(), first)
        try vault.save(second)
        XCTAssertEqual(try vault.readKey(), second)
        try vault.remove()
        XCTAssertFalse(try vault.hasKey())
        XCTAssertThrowsError(try vault.readKey())
    }

    func testRejectsWhitespaceAndEmptyKeys() {
        let vault = OpenRouterSecretVault(service: "com.cliphelm.tests.\(UUID().uuidString)")
        XCTAssertThrowsError(try vault.save(""))
        XCTAssertThrowsError(try vault.save("two words"))
        XCTAssertThrowsError(try vault.save("line\nbreak"))
    }
}
