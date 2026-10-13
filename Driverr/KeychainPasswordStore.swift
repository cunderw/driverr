import DriverrCore
import Foundation
import Security

/// Host passwords in the iOS Keychain, one item per host.
///
/// Same accessibility as `KeychainIdentityStore`: readable after first unlock, never synced.
///
/// Only `PasswordCredentials` writes through this. It owns the remember-or-prompt decision,
/// so the consent rule lives in one place.
struct KeychainPasswordStore: PasswordStore {
  private let service: String

  init(service: String = "com.cunderw.driverr.passwords") {
    self.service = service
  }

  func password(for hostID: UUID) async throws -> String? {
    var query = baseQuery(account: hostID.uuidString)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    // Not found is not a failure: it means "ask the user", which is a normal path.
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw AppError.keyImportFailed(reason: Self.message(for: status))
    }
    return String(decoding: data, as: UTF8.self)
  }

  func save(_ password: String, for hostID: UUID) async throws {
    SecItemDelete(baseQuery(account: hostID.uuidString) as CFDictionary)

    var attributes = baseQuery(account: hostID.uuidString)
    attributes[kSecValueData as String] = Data(password.utf8)
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw AppError.keyImportFailed(reason: Self.message(for: status))
    }
  }

  func delete(for hostID: UUID) async throws {
    let status = SecItemDelete(baseQuery(account: hostID.uuidString) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AppError.keyImportFailed(reason: Self.message(for: status))
    }
  }

  /// Removes every password under this service. Used by tests to clean up.
  func deleteAll() throws {
    let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AppError.keyImportFailed(reason: Self.message(for: status))
    }
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
