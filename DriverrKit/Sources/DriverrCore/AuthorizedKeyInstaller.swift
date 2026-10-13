import Foundation

/// What a key install did when it worked.
public enum KeyInstallOutcome: Hashable, Sendable {
  /// The key was appended to `~/.ssh/authorized_keys`.
  case installed
  /// The key was already in the file, so nothing was written.
  case alreadyInstalled
}

/// Why a key install did not work: the host's answer, or a link that did not carry the
/// command at all.
public enum KeyInstallError: Error, Hashable, Sendable {
  case host(AuthorizedKeyInstallFailure)
  case transport(AppError)

  /// The failure as the sheet says it.
  public var message: String {
    let path = "~/.ssh/authorized_keys"
    switch self {
    case .transport(let error):
      return error.errorDescription ?? "The command could not be run."
    case .host(let failure):
      switch failure {
      case .notARegularFile:
        return "~/.ssh or \(path) on this host is not a regular directory or file, or is a link to nothing. Driverr does not replace it."
      case .couldNotCreateDirectory(let message):
        return "Driverr could not make ~/.ssh on this host." + Self.quoted(message)
      case .unreadable(let message):
        return "Driverr could not read \(path), so nothing was written." + Self.quoted(message)
      case .readOnlyFileSystem:
        return "\(path) is on a read-only file system. Nothing was written."
      case .diskFull:
        return "The host’s disk is full, so the key was not added. Free some space, then try again."
      case .writeFailed(let message):
        return "Driverr could not add the key to \(path)." + Self.quoted(message)
      case .missingTool(let message):
        return "The host could not run a command the install needs." + Self.quoted(message)
      case .commandFailed(let status, let message):
        return "The command failed with exit status \(status)." + Self.quoted(message)
      }
    }
  }

  /// The host's stderr, when it said anything.
  private static func quoted(_ message: String) -> String {
    message.isEmpty ? "" : " The host said: \(message)"
  }
}

/// Adds a public key to the host's `authorized_keys` over a command runner.
public enum AuthorizedKeyInstaller {
  public static func install(
    _ identity: SSHIdentity,
    run: CommandRunner
  ) async -> Result<KeyInstallOutcome, KeyInstallError> {
    let result: CommandResult
    do {
      result = try await run(AuthorizedKeyInstallCommands.install(identity))
    } catch {
      return .failure(.transport(error as? AppError ?? .channelFailed(reason: "The command could not be run.")))
    }
    do {
      return .success(try AuthorizedKeyInstallCommands.outcome(of: result))
    } catch {
      return .failure(.host(error))
    }
  }
}
