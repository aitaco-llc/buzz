import BuzzCore
import Security
import XCTest

@testable import Buzz

final class CredentialsTests: XCTestCase {
  @MainActor func testOneKeychainWritePersistsDiscoverableAccountAndCredentials() throws {
    let service = "com.aitaco.buzz.tests.\(UUID().uuidString)"
    defer { remove(service) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let account = Account(
      id: UUID(), community: try Community(url: "https://buzz.example", name: "Test"),
      pubkey: identity.pubkey)
    XCTAssertTrue(try Credentials.accounts(service: service).isEmpty)
    try Credentials.save(
      Credential(privateKey: identity.privateKeyHex, authTag: "first"), account: account,
      service: service)
    XCTAssertEqual(try Credentials.accounts(service: service), [account])
    XCTAssertEqual(
      try Credentials.load(account: account.id, service: service).privateKey, identity.privateKeyHex
    )
    try Credentials.save(
      Credential(privateKey: identity.privateKeyHex, authTag: "second"), account: account,
      service: service)
    XCTAssertEqual(try Credentials.accounts(service: service), [account])
    XCTAssertEqual(try Credentials.load(account: account.id, service: service).authTag, "second")
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: account.id.uuidString, kSecReturnAttributes: true,
    ]
    var result: CFTypeRef?
    XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
    let attributes = try XCTUnwrap(result as? [CFString: Any])
    XCTAssertEqual(
      attributes[kSecAttrAccessible] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
  }

  @MainActor func testLegacyCredentialCanBeMigratedWithoutLosingIdentity() throws {
    let service = "com.aitaco.buzz.tests.\(UUID().uuidString)"
    defer { remove(service) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let account = Account(
      id: UUID(), community: try Community(url: "https://buzz.example", name: "Legacy"),
      pubkey: identity.pubkey)
    let credential = Credential(privateKey: identity.privateKeyHex, authTag: nil)
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: account.id.uuidString, kSecValueData: try JSONEncoder().encode(credential),
    ]
    XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
    XCTAssertTrue(try Credentials.accounts(service: service).isEmpty)
    let old = try Credentials.load(account: account.id, service: service)
    try Credentials.save(old, account: account, service: service)
    XCTAssertEqual(try Credentials.accounts(service: service), [account])
    XCTAssertEqual(
      try Credentials.load(account: account.id, service: service).privateKey, identity.privateKeyHex
    )
  }

  @MainActor func testMalformedKeychainRecordPropagatesInsteadOfHidingAccounts() throws {
    let service = "com.aitaco.buzz.tests.\(UUID().uuidString)"
    defer { remove(service) }
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: UUID().uuidString, kSecValueData: Data("{}".utf8),
    ]
    XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
    XCTAssertThrowsError(try Credentials.accounts(service: service))
  }

  private func remove(_ service: String) {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
    XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess)
  }
}
