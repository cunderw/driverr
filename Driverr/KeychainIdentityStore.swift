import DriverrCore
import Foundation
import Security

/// Stores SSH identities in the iOS Keychain, one item per identity.
///
/// The private key is written only here and read back only by `privateKey(for:)`. Metadata
/// and key share one Keychain item, so deletion is atomic and nothing is orphaned.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: keys are needed for a background
/// reconnect, so not `WhenUnlocked`, and an SSH key must not move to a new device through a
/// backup, so `ThisDeviceOnly`.
struct KeychainIdentityStore: IdentityStore {
  private let service: String

  init(service: String = "com.cunderw.driverr.identities") {
    self.service = service
  }

  /// What goes in the Keychain item. The private key is stored with its metadata so the two
  /// cannot get out of step.
  private struct Record: Codable {
    let identity: SSHIdentity
    let privateKey: SSHPrivateKey
  }

  func identities() async throws -> [SSHIdentity] {
    try records().map(\.identity).sorted { $0.createdAt > $1.createdAt }
  }

  func add(_ identity: SSHIdentity, privateKey: SSHPrivateKey) async throws {
    let data = try JSONEncoder().encode(Record(identity: identity, privateKey: privateKey))

    // Replace rather than fail if the id exists, so re-importing an identity updates it.
    SecItemDelete(baseQuery(account: identity.id.uuidString) as CFDictionary)

    var attributes = baseQuery(account: identity.id.uuidString)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw AppError.keyImportFailed(reason: Self.message(for: status))
    }
  }

  func privateKey(for id: UUID) async throws -> SSHPrivateKey {
    var query = baseQuery(account: id.uuidString)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      throw AppError.keyImportFailed(reason: "That key is no longer in the Keychain.")
    }
    return try JSONDecoder().decode(Record.self, from: data).privateKey
  }

  func delete(_ id: UUID) async throws {
    let status = SecItemDelete(baseQuery(account: id.uuidString) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AppError.keyImportFailed(reason: Self.message(for: status))
    }
  }

  /// Removes every identity under this service. Tests only; the UI has no delete-all.
  func deleteAll() throws {
    let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AppError.keyImportFailed(reason: Self.message(for: status))
    }
  }

  private func records() throws -> [Record] {
    var query = baseQuery(account: nil)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll

    var items: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &items)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let data = items as? [Data] else {
      throw AppError.keyImportFailed(reason: Self.message(for: status))
    }
    // Skip undecodable items, so one bad item from an older build cannot empty the key list.
    return data.compactMap { try? JSONDecoder().decode(Record.self, from: $0) }
  }

  private func baseQuery(account: String?) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if let account { query[kSecAttrAccount as String] = account }
    return query
  }

  private static func message(for status: OSStatus) -> String {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
    return "The Keychain refused the request: \(detail)"
  }
}
