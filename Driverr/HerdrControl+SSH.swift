import DriverrCore
import DriverrHC
import DriverrHerdr
import DriverrSSH
import DriverrTranscript

/// Joins two modules that do not import each other: `DriverrHerdr` runs herdr through a
/// `CommandRunner` closure, and `DriverrSSH` runs a command on a host.
extension CLIControl {
  init(transport: any SSHTransport, binaryPath: String = "herdr") {
    self.init(binaryPath: binaryPath) { command in
      try await transport.execChannel(command: command)
    }
  }
}

/// The same join for `DriverrHC`, whose one connection is a long-lived stream, not a command.
extension CoreControl {
  static func discovering(transport: any SSHTransport) async -> CoreControl? {
    await discovering(
      run: { try await transport.execChannel(command: $0) },
      open: { ExecStreamBridge(stream: try await transport.execStream(command: $0)) }
    )
  }
}

/// The same join for `DriverrTranscript`, which imports neither of the other two.
extension TranscriptReader {
  init(transport: any SSHTransport) {
    self.init { command in
      try await transport.execChannel(command: command)
    }
  }
}
