import BuzzCore
import Foundation
import Security

struct Account: Codable, Identifiable, Equatable {
  let id: UUID
  let community: Community
  let pubkey: String
}

struct Credential: Codable {
  let privateKey: String
  let authTag: String?
}

enum Credentials {
  private struct Record: Codable {
    let account: Account
    let credential: Credential
    let updatedAt: Date
  }

  // One Keychain update commits identity, community and account discovery together.
  static func save(
    _ credential: Credential, account: Account, service: String = "com.aitaco.buzz.ipad"
  ) throws {
    let data = try JSONEncoder().encode(
      Record(account: account, credential: credential, updatedAt: Date()))
    var query = query(account.id, service: service)
    let status = SecItemUpdate(
      query as CFDictionary,
      [
        kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ] as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData] = data
      query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      try check(SecItemAdd(query as CFDictionary, nil))
    } else {
      try check(status)
    }
  }

  static func load(account: UUID, service: String = "com.aitaco.buzz.ipad") throws -> Credential {
    var query = query(account, service: service)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    try check(SecItemCopyMatching(query as CFDictionary, &result))
    guard let data = result as? Data else { throw BuzzError.invalidKey }
    if let record = try? JSONDecoder().decode(Record.self, from: data) {
      guard record.account.id == account else { throw BuzzError.invalidKey }
      return record.credential
    }
    // Read the initial prototype's credential-only format during manifest migration.
    return try JSONDecoder().decode(Credential.self, from: data)
  }

  static func accounts(service: String = "com.aitaco.buzz.ipad") throws -> [Account] {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecReturnData: true, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    try check(status)
    guard let items = result as? [[CFString: Any]] else { throw BuzzError.invalidKey }
    var records: [Record] = []
    for item in items {
      guard let data = item[kSecValueData] as? Data else { throw BuzzError.invalidKey }
      if let record = try? JSONDecoder().decode(Record.self, from: data) {
        guard item[kSecAttrAccount] as? String == record.account.id.uuidString else {
          throw BuzzError.invalidKey
        }
        records.append(record)
      } else {
        // Legacy records are located by accounts.json and migrated at startup.
        _ = try JSONDecoder().decode(Credential.self, from: data)
      }
    }
    return records.sorted { $0.updatedAt > $1.updatedAt }.map(\.account)
  }

  private static func query(_ account: UUID, service: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: account.uuidString,
    ]
  }

  private static func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw BuzzError.storage(
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
    }
  }
}
