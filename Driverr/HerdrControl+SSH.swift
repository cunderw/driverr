import DriverrCore
import DriverrHC
import DriverrHerdr
import DriverrSSH
import DriverrTmux
import DriverrTranscript

/// Joins two modules that do not import each other: `DriverrHerdr` runs herdr through a
/// `CommandRunner` closure, and `DriverrSSH` runs a command on a host.
///
/// Every join here uses the scripted forms, `posixRunner` and `posixOpen`, so a fish login
/// shell reads each command the way `sh` does. See `LoginShell`.
extension CLIControl {
  init(transport: any SSHTransport, binaryPath: String = "herdr") {
    self.init(binaryPath: binaryPath, run: transport.posixRunner)
  }
}

/// The same join for `DriverrHC`, whose one connection is a long-lived stream, not a command.
extension CoreControl {
  static func discovering(transport: any SSHTransport) async -> CoreControl? {
    await discovering(
      run: transport.posixRunner,
      open: { ExecStreamBridge(stream: try await transport.posixOpen($0)) }
    )
  }
}

/// The same join for `DriverrTmux`, whose live terminal is a long-lived control client.
extension TmuxControl {
  static func discovering(
    transport: any SSHTransport,
    resizesWindow: @escaping @Sendable () async -> Bool
  ) async -> TmuxControl? {
    await discovering(
      run: transport.posixRunner,
      open: { ExecStreamBridge(stream: try await transport.posixOpen($0)) },
      resizesWindow: resizesWindow
    )
  }
}

/// The same join for `DriverrTranscript`, which imports neither of the other two.
extension TranscriptReader {
  init(transport: any SSHTransport) {
    self.init(run: transport.posixRunner)
  }
}
