import Foundation

/// What an install did when it worked.
public enum HookInstallOutcome: Hashable, Sendable {
  /// The settings file was written.
  case installed
  /// Every hook was already there, so nothing was written.
  case alreadyInstalled
}

/// Why a check or an install did not work: the host's answer, or a link that did not carry
/// the command at all.
public enum HookInstallError: Error, Hashable, Sendable {
  case host(HookInstallFailure)
  case transport(AppError)

  /// Whether reading the file again and repeating the install can work: the file moved
  /// under the install, and nothing was written.
  public var isRetryable: Bool {
    switch self {
    case .host(.changedSinceRead), .host(.readDidNotMatch): true
    default: false
    }
  }

  /// The failure as the install sheet says it: the file and the exact reason. It never
  /// quotes the file, so nothing the read returned reaches the screen.
  public func message(for integration: AgentIntegration) -> String {
    let path = integration.displayPath
    switch self {
    case .transport(let error):
      return error.errorDescription ?? "The command could not be run."
    case .host(let failure):
      switch failure {
      case .noConfigDirectory(let directory):
        return "\(directory) does not exist on this host, so \(integration.displayName) has not run here yet. Run it once, then install."
      case .notARegularFile:
        return "\(path) is a symbolic link or not a regular file. Driverr does not replace it."
      case .settings(let error):
        return Self.message(for: error, path: path)
      case .readDidNotMatch:
        return "\(path) changed while Driverr read it. Nothing was written."
      case .changedSinceRead:
        return "\(path) changed after Driverr read it. Nothing was written."
      case .writeDidNotMatch:
        return "The copy written on the host did not match what Driverr sent, so \(path) was not replaced."
      case .checksumFailed(let message):
        return "cksum failed on the host, so nothing was written." + Self.quoted(message)
      case .settingsTooLarge(let bytes):
        return "\(path) would be \(bytes) bytes, which is more than Driverr writes in one install. Nothing was written."
      case .commandFailed(let status, let message):
        return "The command failed with exit status \(status). Nothing was replaced." + Self.quoted(message)
      }
    }
  }

  private static func message(for error: HookSettingsError, path: String) -> String {
    switch error {
    case .invalidJSON:
      return "\(path) is not valid JSON. Driverr does not change it."
    case .unexpectedShape(let key):
      return "\(key) in \(path) is not the kind of value Driverr can add to. Nothing was written."
    case .duplicateKey(let key):
      return "\(key) appears more than once in \(path). Nothing was written."
    case .markerUnderAnotherMatcher(let key):
      return "A Driverr hook is at \(key) in \(path), under another matcher. Move or remove it, then install."
    case .verificationFailed:
      return "Driverr could not verify its edit of \(path), so nothing was written."
    }
  }

  /// The host's stderr, when it said anything. A shell's own error text, never the file.
  private static func quoted(_ message: String) -> String {
    message.isEmpty ? "" : " The host said: \(message)"
  }
}

/// The two ways the hook check and install reach one host.
public struct HookInstallRunners: Sendable {
  /// Runs the read.
  public let run: CommandRunner
  /// Runs the write, with the new file on its standard input.
  public let write: InputCommandRunner

  public init(run: @escaping CommandRunner, write: @escaping InputCommandRunner) {
    self.run = run
    self.write = write
  }
}

/// Reads and installs an integration's hooks over a host's command runners.
///
/// The steps are `HookInstallCommands`' own; this only runs them in order and maps what
/// comes back. It never keeps the file text past one call, and nothing here logs it.
public enum HookInstaller {
  /// Where the integration stands on the host.
  public static func status(
    of integration: AgentIntegration,
    run: CommandRunner
  ) async -> Result<AgentIntegrationStatus, HookInstallError> {
    switch await read(integration, run: run) {
    case .failure(let error):
      return .failure(error)
    case .success(let read):
      let text: String?
      switch read {
      case .missing: text = nil
      case .present(let content, _): text = content
      }
      do {
        return .success(try integration.status(in: text))
      } catch {
        return .failure(.host(.settings(error)))
      }
    }
  }

  /// Reads the file, edits it on this device, and writes it back. A file that changed in
  /// between is not written; the caller repeats the whole install, which reads again.
  ///
  /// The new file goes to `write` as the command's standard input, never in the command.
  /// See `HookInstallCommands`.
  public static func install(
    _ integration: AgentIntegration,
    run: CommandRunner,
    write: InputCommandRunner
  ) async -> Result<HookInstallOutcome, HookInstallError> {
    let read: HookSettingsRead
    switch await self.read(integration, run: run) {
    case .failure(let error): return .failure(error)
    case .success(let value): read = value
    }
    let plan: HookInstallPlan?
    do {
      plan = try HookInstallCommands.plan(for: integration, read: read)
    } catch {
      return .failure(.host(error))
    }
    guard let plan else { return .success(.alreadyInstalled) }
    let result: CommandResult
    do {
      result = try await write(plan.command, Data(plan.settingsText.utf8))
    } catch {
      return .failure(.transport(transportError(error)))
    }
    if let failure = HookInstallCommands.outcome(of: result, for: integration) {
      return .failure(.host(failure))
    }
    return .success(.installed)
  }

  private static func read(
    _ integration: AgentIntegration,
    run: CommandRunner
  ) async -> Result<HookSettingsRead, HookInstallError> {
    let result: CommandResult
    do {
      result = try await run(HookInstallCommands.read(for: integration))
    } catch {
      return .failure(.transport(transportError(error)))
    }
    do {
      return .success(try HookInstallCommands.parseRead(result, for: integration))
    } catch {
      return .failure(.host(error))
    }
  }

  private static func transportError(_ error: any Error) -> AppError {
    error as? AppError ?? .channelFailed(reason: "The command could not be run.")
  }
}

extension HookOfferPolicy {
  /// Whether a host that has just connected is offered the hooks, from what the check found.
  ///
  /// A check that failed is never an offer. A missing configuration directory means the
  /// agent has never run on the host, and any other failure is one the offer could not get
  /// past either; the menu item reports it when someone asks.
  public static func shouldOffer(
    stored: HookOfferState?,
    check: Result<AgentIntegrationStatus, HookInstallError>,
    currentVersion: Int
  ) -> Bool {
    guard case .success(let status) = check else { return false }
    return shouldOffer(stored: stored, hostStatus: status, currentVersion: currentVersion)
  }
}
