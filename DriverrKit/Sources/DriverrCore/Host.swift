import Foundation

/// How Driverr authenticates to a host.
public enum HostAuthMethod: Hashable, Sendable, Codable {
  /// Public-key auth using a specific stored identity.
  case identity(UUID)
  /// Password auth. Whether the password is remembered is `PasswordCredentials`'s decision;
  /// a host never carries a secret.
  case password
}

/// A remote machine Driverr can connect to. Credentials are not stored here; they are in
/// the Keychain, keyed by `id`.
public struct Host: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var name: String
  public var hostname: String
  public var port: Int
  public var username: String
  public var authMethod: HostAuthMethod
  /// Where herdr's socket lives on this host, when it isn't the default.
  ///
  /// Passed to every herdr command as `HERDR_SOCKET_PATH=<value>` (`CLIControl`), the
  /// variable herdr reads. `nil` sends no override.
  public var herdrSocketPath: String?

  public init(
    id: UUID = UUID(),
    name: String,
    hostname: String,
    port: Int = 22,
    username: String,
    authMethod: HostAuthMethod = .password,
    herdrSocketPath: String? = nil
  ) {
    self.id = id
    self.name = name
    self.hostname = hostname
    self.port = port
    self.username = username
    self.authMethod = authMethod
    self.herdrSocketPath = herdrSocketPath
  }

  public var displayName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "\(username)@\(hostname)" : trimmed
  }

  /// Decoded leniently so hosts written before these fields existed still load.
  ///
  /// A decode failure would empty the user's host list on upgrade.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    hostname = try container.decode(String.self, forKey: .hostname)
    port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
    username = try container.decode(String.self, forKey: .username)
    authMethod =
      try container.decodeIfPresent(HostAuthMethod.self, forKey: .authMethod) ?? .password
    herdrSocketPath = try container.decodeIfPresent(String.self, forKey: .herdrSocketPath)
  }
}
